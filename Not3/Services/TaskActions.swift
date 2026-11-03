import Foundation
import SwiftData

/// Status changes shared by the Today list and the evening notification buttons.
@MainActor
enum TaskActions {
    static func task(id: UUID, in context: ModelContext) -> TaskItem? {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func setDone(_ task: TaskItem, _ done: Bool, serverPushActive: Bool) async {
        task.status = done ? .done : .todo
        if done { task.reopenedAt = nil; task.reopenedReason = nil }
        RemindersService.shared.pushCompletion(of: task)
        if done {
            NotificationService.cancelReminder(for: task.id)
        } else {
            await NotificationService.scheduleTaskNotifications(for: task, serverPushActive: serverPushActive)
        }
    }

    /// "Dời sang mai": same time tomorrow (or tomorrow 14:00 when it had no time).
    static func postponeToTomorrow(_ task: TaskItem, serverPushActive: Bool, now: Date = Date()) async {
        let base = task.plannedAt ?? DayClock.at(hour: 14, minute: 0, on: now)
        var next = DayClock.calendar.date(byAdding: .day, value: 1, to: base) ?? base
        while next <= now {
            next = DayClock.calendar.date(byAdding: .day, value: 1, to: next) ?? next
        }
        task.plannedAt = next
        task.status = .todo
        task.postponeCount += 1
        if let sentence = task.ifThenSentence {
            task.ifThenSentence = tomorrowSentence(sentence)
        }
        task.touch()
        CalendarService.shared.writePlan(task)
        await NotificationService.scheduleTaskNotifications(for: task, serverPushActive: serverPushActive)
    }

    /// "Hộp chờ": no day, no reminder, no calendar event.
    static func moveToBacklog(_ task: TaskItem) {
        task.isSomeday = true
        task.plannedAt = nil
        task.ifThenSentence = nil
        if task.status == .doing { task.status = .todo }
        task.touch()
        NotificationService.cancelReminder(for: task.id)
        CalendarService.shared.removePlan(task)
    }

    /// Out of the "Hộp chờ" (or rescheduled): today without a time, or at `date`.
    static func schedule(_ task: TaskItem, at date: Date?, serverPushActive: Bool) async {
        task.isSomeday = false
        task.plannedAt = date
        task.ifThenSentence = nil
        if task.status == .done || task.status == .cancelled { task.status = .todo }
        task.touch()
        if date != nil, task.calendarEventId != nil || UserDefaults.standard.bool(forKey: SettingsKey.addToCalendar) {
            CalendarService.shared.writePlan(task)
        } else if date == nil {
            CalendarService.shared.removePlan(task)
        }
        await NotificationService.scheduleTaskNotifications(for: task, serverPushActive: serverPushActive)
    }

    /// Header menu on "Việc hôm nay": every task carried over from an earlier day at once.
    static func postponeAll(_ tasks: [TaskItem], serverPushActive: Bool, now: Date = Date()) async {
        for task in tasks where TodayList.isCarriedOver(task, now: now) {
            await postponeToTomorrow(task, serverPushActive: serverPushActive, now: now)
        }
    }

    static func backlogAll(_ tasks: [TaskItem], now: Date = Date()) {
        for task in tasks where TodayList.isCarriedOver(task, now: now) {
            moveToBacklog(task)
        }
    }

    /// Cancel: drop reminders and the calendar event.
    static func cancel(_ task: TaskItem) {
        task.status = .cancelled
        NotificationService.cancelReminder(for: task.id)
        CalendarService.shared.removePlan(task)
    }

    // MARK: Xếp lại (the plan slipped)

    /// Start of the next free stretch today for this task, around meetings and other plans.
    static func nextGap(for task: TaskItem, now: Date = Date()) -> Date? {
        let others = (try? task.modelContext?.fetch(FetchDescriptor<TaskItem>())) ?? []
        let busy = CalendarService.shared.busyIntervals(on: now, tasks: others, excluding: task.id)
        return CheckInPlanner.nextGap(now: now, duration: task.durationMinutes ?? 30, busy: busy)
    }

    /// 20:00 today while there is still time before it.
    static func eveningSlot(now: Date = Date()) -> Date? {
        let evening = DayClock.at(hour: 20, minute: 0, on: now)
        return evening > now.addingTimeInterval(5 * 60) ? evening : nil
    }

    /// Same day, new time: reminders, calendar event and the if–then sentence follow.
    static func reschedule(_ task: TaskItem, to date: Date, serverPushActive: Bool, now: Date = Date()) async {
        task.plannedAt = date
        task.isSomeday = false
        if task.status != .doing { task.status = .todo }
        task.postponeCount += 1
        rewriteSentence(task, now: now)
        task.touch()
        if task.calendarEventId != nil { CalendarService.shared.writePlan(task) }
        await NotificationService.scheduleTaskNotifications(for: task, serverPushActive: serverPushActive)
    }

    /// "Làm 10 phút": the short version, started now (Bắt đầu → Xong still measures the real time).
    static func startShortVersion(_ task: TaskItem, now: Date = Date()) {
        task.durationMinutes = CopingPlan.shortMinutes
        task.plannedAt = now
        task.isSomeday = false
        rewriteSentence(task, now: now)
        task.status = .doing
        if task.calendarEventId != nil { CalendarService.shared.writePlan(task) }
        NotificationService.cancelReminder(for: task.id)
    }

    /// Carries out the backup picked at check-in. False when it cannot apply today (no free
    /// stretch left, evening already passed): the caller offers the other choices.
    @discardableResult
    static func applyCoping(_ task: TaskItem, serverPushActive: Bool, now: Date = Date()) async -> Bool {
        switch task.coping {
        case .shorter:
            startShortVersion(task, now: now)
        case .nextGap:
            guard let gap = nextGap(for: task, now: now) else { return false }
            await reschedule(task, to: gap, serverPushActive: serverPushActive, now: now)
        case .evening:
            guard let evening = eveningSlot(now: now) else { return false }
            await reschedule(task, to: evening, serverPushActive: serverPushActive, now: now)
        case .tomorrow:
            await postponeToTomorrow(task, serverPushActive: serverPushActive, now: now)
        case nil:
            return false
        }
        return true
    }

    /// "Dời hết sang mai" on the "Khép lại hôm nay" notification: every open task the user sorts
    /// moves on (planned ones to the same time tomorrow, undated ones simply carry over), and the
    /// day is closed with its feeling unchanged.
    static func closeDayMovingRest(in context: ModelContext, serverPushActive: Bool, now: Date = Date()) async {
        let all = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        for task in TodayList.tasks(all, now: now)
        where (task.status == .todo || task.status == .doing) && TodayList.needsShutdownDecision(task) {
            if task.plannedAt != nil {
                await postponeToTomorrow(task, serverPushActive: serverPushActive, now: now)
            } else {
                task.postponeCount += 1
            }
        }
        let existing = CheckInService.todaysCheckIn(context, now: now)
        CheckInService.closeDay(mood: existing?.dayMood, moodLabel: existing?.dayMoodLabel, in: context, now: now)
    }

    /// "Vẫn làm" to "Vẫn muốn làm?": asked again only after it slips a few more times.
    static func keep(_ task: TaskItem, now: Date = Date()) {
        task.keptAt = now
        task.postponeCount = 0
    }

    /// Keeps a plan's sentence true after its time changed (nothing to do without a sentence).
    private static func rewriteSentence(_ task: TaskItem, now: Date) {
        guard task.ifThenSentence != nil else { return }
        task.ifThenSentence = CheckInPlanner.sentence(task: task.title, at: task.plannedAt,
                                                      duration: task.durationMinutes, coping: task.coping, now: now)
    }

    /// Keeps the if–then wording true for the new day: "Lúc 14:00, …" → "Mai lúc 14:00, …".
    nonisolated static func tomorrowSentence(_ sentence: String) -> String {
        let swaps = [("Lúc ", "Mai lúc "), ("Tối nay", "Tối mai"), ("Chiều nay", "Chiều mai")]
        for (old, new) in swaps where sentence.hasPrefix(old) {
            return new + sentence.dropFirst(old.count)
        }
        return sentence
    }

    /// Handles the reminder buttons: "Bắt đầu" (→ đang làm), "Đã xong" and "Lỡ giờ? Xếp lại"
    /// (the backup picked at check-in, else the next free stretch, else tomorrow).
    static func handleReminder(action: String, taskId: UUID, in context: ModelContext, serverPushActive: Bool) async {
        guard let task = task(id: taskId, in: context) else { return }
        switch action {
        case NotificationService.reminderStartAction:
            guard task.status == .todo else { return }
            task.status = .doing
        case NotificationService.reminderDoneAction:
            await setDone(task, true, serverPushActive: serverPushActive)
        case NotificationService.reminderReplanAction:
            guard task.status == .todo else { return }
            if await applyCoping(task, serverPushActive: serverPushActive) {
                break
            } else if let gap = nextGap(for: task) {
                await reschedule(task, to: gap, serverPushActive: serverPushActive)
            } else {
                await postponeToTomorrow(task, serverPushActive: serverPushActive)
            }
        default:
            return
        }
        try? context.save()
    }

    /// Handles the evening notification buttons.
    static func handleEvening(action: String, taskId: UUID, in context: ModelContext, serverPushActive: Bool) async {
        guard let task = task(id: taskId, in: context) else { return }
        switch action {
        case NotificationService.eveningDoneAction:
            await setDone(task, true, serverPushActive: serverPushActive)
        case NotificationService.eveningTomorrowAction:
            await postponeToTomorrow(task, serverPushActive: serverPushActive)
        default:
            return
        }
        try? context.save()
    }
}
