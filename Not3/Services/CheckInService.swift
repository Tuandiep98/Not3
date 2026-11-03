import Foundation
import SwiftData

/// Writes check-ins and plans. Used by the sheet and by notification actions.
@MainActor
enum CheckInService {
    static func todaysCheckIn(_ context: ModelContext, now: Date = Date()) -> CheckIn? {
        let day = DayClock.startOfDay(now)
        var descriptor = FetchDescriptor<CheckIn>(predicate: #Predicate { $0.day == day })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    static func checkIn(for now: Date = Date(), in context: ModelContext) -> CheckIn {
        if let existing = todaysCheckIn(context, now: now) { return existing }
        let checkIn = CheckIn(day: DayClock.startOfDay(now))
        context.insert(checkIn)
        return checkIn
    }

    /// Quick answer from the notification / widget buttons.
    static func recordMood(_ mood: Mood, in context: ModelContext) {
        let checkIn = checkIn(in: context)
        checkIn.mood = mood
        bumpChip(group: .mood, label: mood.label, in: context)
        try? context.save()
    }

    struct Plan {
        var morningItems: [String]
        var mood: Mood?
        var task: AfternoonSuggestion?
        var time: TimeOption?
        var durationMinutes: Int?
    }

    @discardableResult
    static func save(_ plan: Plan, in context: ModelContext) -> TaskItem? {
        let checkIn = checkIn(in: context)
        checkIn.morningItems = plan.morningItems
        checkIn.mood = plan.mood
        if let mood = plan.mood { bumpChip(group: .mood, label: mood.label, in: context) }

        var created: TaskItem?
        if let suggestion = plan.task {
            let sentence = CheckInPlanner.sentence(task: suggestion.title, time: plan.time, duration: plan.durationMinutes)
            let task: TaskItem
            if let id = suggestion.taskId, let existing = TaskActions.task(id: id, in: context) {
                // Unfinished morning work (or a "Hộp chờ" item) moved to the afternoon: same task, new time.
                task = existing
                task.isSomeday = false
                task.plannedAt = plan.time?.date
                task.durationMinutes = plan.durationMinutes ?? task.durationMinutes
                if task.status == .done || task.status == .cancelled { task.status = .todo }
                task.ifThenSentence = sentence
                task.touch()
            } else {
                task = TaskItem(
                    title: suggestion.title,
                    category: suggestion.category,
                    plannedAt: plan.time?.date,
                    durationMinutes: plan.durationMinutes,
                    source: suggestion.source
                )
                task.ifThenSentence = sentence
                context.insert(task)
            }
            if !checkIn.afternoonTaskIds.contains(task.id) { checkIn.afternoonTaskIds.append(task.id) }
            created = task

            if let category = suggestion.category { bumpChip(group: .category, label: category, in: context) }
            if let duration = plan.durationMinutes { bumpChip(group: .duration, label: "\(duration)p", in: context) }
            if let time = plan.time { bumpChip(group: .time, label: time.label, in: context) }
        }
        checkIn.needsSync = true
        try? context.save()
        return created
    }

    static func bumpChip(group: ChipGroup, label: String, in context: ModelContext) {
        let raw = group.rawValue
        let descriptor = FetchDescriptor<Chip>(predicate: #Predicate { $0.groupRaw == raw && $0.label == label })
        let chip = (try? context.fetch(descriptor).first) ?? {
            let chip = Chip(group: group, label: label, isBuiltIn: false)
            context.insert(chip)
            return chip
        }()
        chip.useCount += 1
        chip.lastUsedAt = Date()
    }
}
