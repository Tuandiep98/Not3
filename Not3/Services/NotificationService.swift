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
    nonisolated static let reminderCategory = "REMINDER"
    nonisolated static let reminderStartAction = "REMINDER_START"
    nonisolated static let reminderDoneAction = "REMINDER_DONE"
    nonisolated static let reminderReplanAction = "REMINDER_REPLAN"
    nonisolated static let shutdownCategory = "SHUTDOWN"
    nonisolated static let shutdownTomorrowAction = "SHUTDOWN_TOMORROW"
    nonisolated static let syncCategories = ["SYNC_GITHUB": "Mở trên GitHub", "SYNC_JIRA": "Mở trên Jira"]
    nonisolated static let openExternalAction = "OPEN_EXTERNAL"
    nonisolated static let taskIdKey = "task_id"
    nonisolated static let linkKey = "link"
    nonisolated static let urlKey = "url"
    private static let eveningIdPrefix = "evening-"
    private static let checkInIdPrefix = "local-checkin-"
    private static let taskIdPrefix = "task-"
    private static let shutdownIdPrefix = "local-shutdown-"

    static func registerCategories() {
        let actions = Mood.allCases.map { mood in
            UNNotificationAction(identifier: moodActionPrefix + mood.rawValue, title: ChipStore.quickMoodLabel(mood), options: [])
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
                UNNotificationAction(identifier: eveningDoneAction, title: "Xong", options: [],
                                     icon: UNNotificationActionIcon(systemImageName: "checkmark")),
                UNNotificationAction(identifier: eveningTomorrowAction, title: "Dời sang mai", options: [],
                                     icon: UNNotificationActionIcon(systemImageName: "arrow.turn.up.right")),
            ],
            intentIdentifiers: [],
            options: []
        )
        let reminder = UNNotificationCategory(
            identifier: reminderCategory,
            actions: [
                UNNotificationAction(identifier: reminderStartAction, title: "Bắt đầu", options: [],
                                     icon: UNNotificationActionIcon(systemImageName: "play.fill")),
                UNNotificationAction(identifier: reminderDoneAction, title: "Đã xong", options: [],
                                     icon: UNNotificationActionIcon(systemImageName: "checkmark")),
                // The backup picked at check-in, else the next free stretch today, else tomorrow.
                UNNotificationAction(identifier: reminderReplanAction, title: "Lỡ giờ? Xếp lại", options: [],
                                     icon: UNNotificationActionIcon(systemImageName: "calendar.badge.clock")),
            ],
            intentIdentifiers: [],
            options: []
        )
        // Replaces the per-task "Xong chưa?" while on: tap to sort, or move everything left in one go.
        let shutdown = UNNotificationCategory(
            identifier: shutdownCategory,
            actions: [
                UNNotificationAction(identifier: shutdownTomorrowAction, title: "Dời hết sang mai", options: [],
                                     icon: UNNotificationActionIcon(systemImageName: "arrow.turn.up.right")),
            ],
            intentIdentifiers: [],
            options: []
        )
        // "Đã xong: …" / "Cần làm lại: …" pushes: jump straight to the PR / ticket.
        let sync = syncCategories.map { id, title in
            UNNotificationCategory(
                identifier: id,
                actions: [UNNotificationAction(identifier: openExternalAction, title: title, options: [.foreground],
                                               icon: UNNotificationActionIcon(systemImageName: "arrow.up.right.square"))],
                intentIdentifiers: [],
                options: []
            )
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set([category, evening, reminder, shutdown] + sync))
    }

    /// "Khép lại hôm nay" for the next 7 days, skipping today once the day is closed. On device
    /// only (the server does not send it), so it does not depend on server push. While on, it is
    /// the only evening notification: the per-task "Xong chưa?" ones are dropped here.
    /// Re-run after saves (`WidgetBridge`), so today's text names what is still open.
    static func rescheduleShutdown(in context: ModelContext) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let enabled = AppSettings.shutdownEnabled
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter {
                $0.hasPrefix(shutdownIdPrefix) || (enabled && $0.hasPrefix(eveningIdPrefix))
            }
        )
        guard enabled else { return }

        let closedToday = CheckInService.todaysCheckIn(context)?.closedAt != nil
        let now = Date()
        let open = TodayList.tasks((try? context.fetch(FetchDescriptor<TaskItem>())) ?? [], now: now)
            .filter { $0.status == .todo || $0.status == .doing }
        for offset in 0..<7 {
            guard let day = DayClock.calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let fire = offset == 0 ? shutdownTimeToday(open: open, now: now) : AppSettings.shutdownTime(on: day)
            if fire <= now { continue }
            if offset == 0, closedToday { continue }

            let content = UNMutableNotificationContent()
            content.title = "Khép lại hôm nay"
            content.body = offset == 0 ? Copy.shutdownBody(open) : Copy.shutdownBody(nil)
            content.sound = .default
            content.categoryIdentifier = shutdownCategory
            content.style(.active, relevance: 0.5, thread: "shutdown", link: "not3://shutdown")
            let comps = DayClock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let request = UNNotificationRequest(
                identifier: shutdownIdPrefix + "\(comps.year!)-\(comps.month!)-\(comps.day!)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            )
            try? await center.add(request)
        }
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
            content.body = "Buổi sáng thế nào? Nhấn giữ để chọn tâm trạng, chạm để lên kế hoạch chiều."
            content.sound = .default
            content.categoryIdentifier = checkInCategory
            content.style(.active, relevance: 0.8, thread: "checkin", link: "not3://checkin")
            let comps = DayClock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let request = UNNotificationRequest(
                identifier: checkInIdPrefix + "\(comps.year!)-\(comps.month!)-\(comps.day!)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            )
            try? await center.add(request)
        }
    }

    /// The set time, or 15 minutes after the last plan of the day ends if that is later
    /// (as the per-task check did), at the latest 23:30.
    static func shutdownTimeToday(open: [TaskItem], now: Date = Date()) -> Date {
        let set = AppSettings.shutdownTime(on: now)
        let lastEnd = open.compactMap { task -> Date? in
            guard let planned = task.plannedAt, DayClock.calendar.isDate(planned, inSameDayAs: now) else { return nil }
            return planned.addingTimeInterval(Double((task.durationMinutes ?? 0) + 15) * 60)
        }.max()
        return min(max(set, lastEnd ?? set), DayClock.at(hour: 23, minute: 30, on: now))
    }

    /// Reminder at the planned time of an if–then plan.
    static func scheduleReminder(for task: TaskItem) async {
        guard let date = task.plannedAt, date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = Copy.title("Bắt đầu: ", task.title)
        content.body = Copy.reminderBody(task)
        content.sound = .default
        content.categoryIdentifier = reminderCategory
        content.userInfo = [taskIdKey: task.id.uuidString]
        // A time the user chose: allowed through Focus.
        content.style(.timeSensitive, relevance: 1, thread: "tasks", link: "not3://task/\(task.id.uuidString)")
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
        guard AppSettings.perTaskEveningCheck, let fire = eveningTime(for: task), fire > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = Copy.title("Xong chưa: ", task.title)
        content.body = "Nhấn giữ để chọn Xong hoặc Dời sang mai."
        content.sound = .default
        content.categoryIdentifier = eveningCategory
        content.userInfo = [taskIdKey: task.id.uuidString]
        content.style(.active, relevance: 0.6, thread: "tasks", link: "not3://task/\(task.id.uuidString)")
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

    /// Server push turned on → drop every local check-in / reminder / "Xong chưa?" it duplicates
    /// (scheduled earlier as a fallback, e.g. before the device token was checked). Turned off →
    /// put them back for the tasks still to do.
    static func serverPushChanged(active: Bool, in context: ModelContext) async {
        await rescheduleCheckIns(in: context, serverPushActive: active)
        if active {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(
                withIdentifiers: pending.map(\.identifier).filter {
                    $0.hasPrefix(taskIdPrefix) || $0.hasPrefix(eveningIdPrefix)
                }
            )
        } else {
            let tasks = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
            for task in tasks where task.plannedAt != nil {
                await scheduleTaskNotifications(for: task, serverPushActive: false)
            }
        }
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

/// Wording shared with the server (supabase/functions/_shared/notify.ts, migration push_copy):
/// the title says what, the body says why and the next step.
enum Copy {
    static let maxTitle = 64

    static func title(_ prefix: String, _ text: String) -> String {
        let full = prefix + text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard full.count > maxTitle else { return full }
        return String(full.prefix(maxTitle - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Today: what is still open ("Còn 2 việc: Đọc sách, Viết test…"); later days: generic.
    @MainActor
    static func shutdownBody(_ open: [TaskItem]?) -> String {
        guard let open else { return "Xem lại việc đã xong, xếp việc còn lại cho mai. Mất khoảng 1 phút." }
        guard !open.isEmpty else { return "Không còn việc dang dở. Chạm để ghi cảm nhận cả ngày." }
        let names = open.prefix(3).map(\.title).joined(separator: ", ") + (open.count > 3 ? "…" : "")
        return "Còn \(open.count) việc: \(names). Chạm để xếp, nhấn giữ để dời hết sang mai."
    }

    @MainActor
    static func reminderBody(_ task: TaskItem) -> String {
        let sentence = task.ifThenSentence?.trimmingCharacters(in: .whitespaces)
        var body = (sentence?.isEmpty == false ? sentence : nil)
            ?? task.plannedAt.map { "Đến giờ bạn đã hẹn lúc \(DayClock.time($0))" }
            ?? "Đến giờ bạn đã hẹn"
        if let minutes = task.durationMinutes, minutes > 0 { body += " · \(minutes) phút" }
        return body
    }
}

extension UNMutableNotificationContent {
    /// Interruption level, order in the summary, grouping and the tap destination.
    func style(_ level: UNNotificationInterruptionLevel, relevance: Double, thread: String, link: String) {
        interruptionLevel = level
        relevanceScore = relevance
        threadIdentifier = thread
        userInfo[NotificationService.linkKey] = link
    }
}
