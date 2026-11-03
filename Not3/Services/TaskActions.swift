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

    /// Keeps the if–then wording true for the new day: "Lúc 14:00, …" → "Mai lúc 14:00, …".
    nonisolated static func tomorrowSentence(_ sentence: String) -> String {
        let swaps = [("Lúc ", "Mai lúc "), ("Tối nay", "Tối mai"), ("Chiều nay", "Chiều mai")]
        for (old, new) in swaps where sentence.hasPrefix(old) {
            return new + sentence.dropFirst(old.count)
        }
        return sentence
    }

    /// Handles the reminder buttons: "Bắt đầu" (→ đang làm) and "Đã xong".
    static func handleReminder(action: String, taskId: UUID, in context: ModelContext, serverPushActive: Bool) async {
        guard let task = task(id: taskId, in: context) else { return }
        switch action {
        case NotificationService.reminderStartAction:
            guard task.status == .todo else { return }
            task.status = .doing
        case NotificationService.reminderDoneAction:
            await setDone(task, true, serverPushActive: serverPushActive)
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
