import Foundation
import SwiftData
import UserNotifications

/// Local notifications. Server push (APNs from Supabase) is primary; these are the on-device
/// fallback for the 12:00 check-in plus reminders for if–then plans.
@MainActor
enum NotificationService {
    nonisolated static let checkInCategory = "CHECKIN"
    nonisolated static let moodActionPrefix = "MOOD_"
    nonisolated static let eveningCategory = "EVENING"
    nonisolated static let eveningDoneAction = "EVENING_DONE"
    nonisolated static let eveningTomorrowAction = "EVENING_TOMORROW"
    nonisolated static let taskIdKey = "task_id"
    private static let eveningIdPrefix = "evening-"
    private static let checkInIdPrefix = "local-checkin-"
    private static let taskIdPrefix = "task-"

    static func registerCategories() {
        let actions = Mood.allCases.map { mood in
            UNNotificationAction(identifier: moodActionPrefix + mood.rawValue, title: mood.label, options: [])
        }
        let category = UNNotificationCategory(
            identifier: checkInCategory,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let evening = UNNotificationCategory(
            identifier: eveningCategory,
            actions: [
                UNNotificationAction(identifier: eveningDoneAction, title: "Xong", options: []),
                UNNotificationAction(identifier: eveningTomorrowAction, title: "Dời sang mai", options: []),
            ],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category, evening])
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Schedules the 12:00 check-in for the next 7 days, skipping today if already checked in.
    /// Called on launch, on foreground and after each check-in.
    static func rescheduleCheckIns(in context: ModelContext, serverPushActive: Bool) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(checkInIdPrefix) }
        )
        guard AppSettings.localFallback, !serverPushActive else { return }

        let alreadyCheckedIn = CheckInService.todaysCheckIn(context)?.mood != nil
        let now = Date()
        for offset in 0..<7 {
            guard let day = DayClock.calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let fire = DayClock.at(hour: AppSettings.checkInHour, minute: AppSettings.checkInMinute, on: day)
            if fire <= now { continue }
            if offset == 0, alreadyCheckedIn { continue }

            let content = UNMutableNotificationContent()
            content.title = "Check-in buổi trưa"
            content.body = "Buổi sáng của bạn thế nào? Chạm để lên kế hoạch chiều."
            content.sound = .default
            content.categoryIdentifier = checkInCategory
            let comps = DayClock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let request = UNNotificationRequest(
                identifier: checkInIdPrefix + "\(comps.year!)-\(comps.month!)-\(comps.day!)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            )
            try? await center.add(request)
        }
    }

    /// Reminder at the planned time of an if–then plan.
    static func scheduleReminder(for task: TaskItem) async {
        guard let date = task.plannedAt, date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Đến giờ rồi"
        content.body = task.ifThenSentence ?? task.title
        content.sound = .default
        let comps = DayClock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(
            identifier: taskIdPrefix + task.id.uuidString,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Evening follow-up "Đã làm chưa?" with Xong / Dời sang mai.
    static func scheduleEveningCheck(for task: TaskItem) async {
        guard UserDefaults.standard.bool(forKey: SettingsKey.eveningCheckIn),
              let fire = eveningTime(for: task), fire > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Đã làm chưa?"
        content.body = task.title
        content.sound = .default
        content.categoryIdentifier = eveningCategory
        content.userInfo = [taskIdKey: task.id.uuidString]
        let comps = DayClock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let request = UNNotificationRequest(
            identifier: eveningIdPrefix + task.id.uuidString,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// 21:00 on the planned day, or 15 minutes after the task ends if that is later.
    static func eveningTime(for task: TaskItem) -> Date? {
        guard let planned = task.plannedAt else { return nil }
        let nine = DayClock.at(hour: 21, minute: 0, on: planned)
        let end = planned.addingTimeInterval(Double((task.durationMinutes ?? 0) + 15) * 60)
        return max(nine, end)
    }

    /// Local reminder + evening check, only when the server is not already pushing them.
    static func scheduleTaskNotifications(for task: TaskItem, serverPushActive: Bool) async {
        cancelReminder(for: task.id)
        guard !serverPushActive, task.status == .todo else { return }
        await scheduleReminder(for: task)
        await scheduleEveningCheck(for: task)
    }

    static func cancelReminder(for taskId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [taskIdPrefix + taskId.uuidString, eveningIdPrefix + taskId.uuidString]
        )
    }
}
