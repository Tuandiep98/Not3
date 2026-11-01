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
