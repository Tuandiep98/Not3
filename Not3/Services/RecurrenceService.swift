import Foundation
import SwiftData

/// Creates today's occurrence of every active repeating task. Runs on device (foreground,
/// background refresh); occurrences sync to Supabase like any other task.
@MainActor
enum RecurrenceService {
    /// Returns the occurrences created now (already inserted and saved).
    @discardableResult
    static func generate(in context: ModelContext, now: Date = Date(), serverPushActive: Bool) async -> [TaskItem] {
        let created = generateOccurrences(in: context, now: now)
        for task in created {
            if task.plannedAt != nil, let owner = Self.series(id: task.seriesId, in: context), owner.addToCalendar {
                CalendarService.shared.writePlan(task)
            }
            await NotificationService.scheduleTaskNotifications(for: task, serverPushActive: serverPushActive)
        }
        return created
    }

    /// Pure SwiftData part (no notifications / calendar), so tests can run it.
    @discardableResult
    static func generateOccurrences(in context: ModelContext, now: Date = Date()) -> [TaskItem] {
        let today = DayClock.startOfDay(now)
        let all = (try? context.fetch(FetchDescriptor<TaskSeries>(predicate: #Predicate { $0.isActive }))) ?? []
        var created: [TaskItem] = []
        for series in all where series.startDay <= today && series.rule.occurs(on: today) {
            if let last = series.lastGeneratedDay, last >= today { continue }
            let id = series.id
            let occurrences = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.seriesId == id }))) ?? []
            // The previous occurrence left open would otherwise carry over forever next to the new one.
            for old in occurrences where (old.status == .todo || old.status == .doing) && (old.plannedAt ?? old.createdAt) < today {
                old.status = .cancelled
                NotificationService.cancelReminder(for: old.id)
            }
            series.lastGeneratedDay = today
            guard !occurrences.contains(where: { ($0.plannedAt ?? $0.createdAt) >= today }) else { continue }
            let task = makeOccurrence(of: series, on: today, now: now)
            context.insert(task)
            created.append(task)
        }
        try? context.save()
        return created
    }

    static func makeOccurrence(of series: TaskSeries, on day: Date, now: Date = Date()) -> TaskItem {
        let planned = series.hour.map { DayClock.at(hour: $0, minute: series.minute ?? 0, on: day) }
        let task = TaskItem(title: series.title, category: series.category, plannedAt: planned,
                            durationMinutes: series.durationMinutes, source: .manual)
        task.seriesId = series.id
        task.createdAt = now
        return task
    }

    static func series(id: UUID?, in context: ModelContext) -> TaskSeries? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<TaskSeries>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Turns a task into the first occurrence of a new series (from the task editor).
    static func makeRepeating(_ task: TaskItem, rule: Recurrence, addToCalendar: Bool, in context: ModelContext) -> TaskSeries {
        let series = TaskSeries(title: task.title, category: task.category, rule: rule, startDay: task.plannedAt ?? Date())
        apply(task: task, to: series)
        series.addToCalendar = addToCalendar
        // Today's occurrence is this task: do not create a second one.
        if rule.occurs(on: series.startDay) { series.lastGeneratedDay = series.startDay }
        context.insert(series)
        task.seriesId = series.id
        task.touch()
        return series
    }

    /// Copies title / time / duration edits of an occurrence back to its series (future days).
    static func apply(task: TaskItem, to series: TaskSeries) {
        series.title = task.title
        series.category = task.category
        if let planned = task.plannedAt {
            let comps = DayClock.calendar.dateComponents([.hour, .minute], from: planned)
            series.hour = comps.hour
            series.minute = comps.minute
        } else {
            series.hour = nil
            series.minute = nil
        }
        series.durationMinutes = task.durationMinutes
        series.touch()
    }

    /// "Dừng lặp": no new occurrences; existing ones stay as they are.
    static func stop(_ series: TaskSeries) {
        series.isActive = false
        series.touch()
    }
}
