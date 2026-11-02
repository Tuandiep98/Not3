import SwiftData
import SwiftUI
import UIKit
import UserNotifications

@main
struct Not3App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppSettings.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(Router.shared)
                .environment(SupabaseService.shared)
                .environment(CalendarService.shared)
                .tint(Theme.accentInk)
                .task { await AppLifecycle.onLaunch() }
                .onOpenURL { Router.shared.open($0) }
        }
        .modelContainer(Persistence.shared)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await AppLifecycle.onForeground() }
            case .background:
                // Widgets show the latest state; iOS wakes us later to refresh.
                WidgetBridge.publish()
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
    }
}

@MainActor
enum AppLifecycle {
    static func onLaunch() async {
        let context = Persistence.shared.mainContext
        Persistence.seedIfNeeded(context)
        Persistence.mergeDuplicateFolders(context)
        CalendarService.shared.startObserving()
        WidgetBridge.startObserving()
        NotificationService.registerCategories()
        // Permission is asked in context (first check-in save), not on first launch.
        UIApplication.shared.registerForRemoteNotifications()
        await SupabaseService.shared.restoreSession()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-openCheckIn") { Router.shared.openCheckIn() }
        if args.contains("-openFolders") { Router.shared.path = [] }
        if args.contains("-seedSample") { seedSample(context) }
        if args.contains("-fakeIntegrations") { SupabaseService.shared.useFakeIntegrations() }
        #endif
        await onForeground()
    }

    static func onForeground() async {
        let context = Persistence.shared.mainContext
        let supabase = SupabaseService.shared
        // Ticks / moods / starts done on widgets while the app was closed.
        await WidgetBridge.applyPendingActions(serverPushActive: supabase.hasServerPush)
        await NotificationService.rescheduleCheckIns(in: context, serverPushActive: supabase.hasServerPush)
        await CalendarService.shared.refresh(in: context)
        await supabase.syncPending(context)
        await supabase.uploadCalendarItems(context)
        await supabase.pullContentRules()
        await supabase.pullExternalItems(context)
        await supabase.pullTaskUpdates(context)
        await supabase.pullLinks(context)
        await supabase.pullNoteSuggestions(context)
        JournalService.updateToday(in: context)
        supabase.markRefreshed()
        WidgetBridge.publish()
    }

    /// BGAppRefreshTask and silent pushes: same data pass, no UI work, then the widgets.
    static func backgroundRefresh() async {
        let context = Persistence.shared.mainContext
        let supabase = SupabaseService.shared
        if !supabase.isSignedIn { await supabase.restoreSession() }
        await WidgetBridge.applyPendingActions(serverPushActive: supabase.hasServerPush)
        await CalendarService.shared.refresh(in: context)
        await supabase.syncPending(context)
        await supabase.uploadCalendarItems(context)
        await supabase.pullContentRules()
        await supabase.pullExternalItems(context)
        await supabase.pullTaskUpdates(context)
        await supabase.pullLinks(context)
        JournalService.updateToday(in: context)
        supabase.markRefreshed()
        WidgetBridge.publish()
    }

    #if DEBUG
    /// Sample day for simulator screenshots (`-seedSample`).
    private static func seedSample(_ context: ModelContext) {
        guard (try? context.fetchCount(FetchDescriptor<TaskItem>())) == 0 else { return }
        let samples: [(String, String, Int?, Int?, Bool)] = [
            ("Review PR #42", "Công việc", 9, nil, true),
            ("Học 20 từ vựng Anki", "Học ngôn ngữ", 14, 25, true),
            ("Viết test module login", "Công việc", 16, 45, false),
            ("JIRA-120: Push 12h", "Công việc", nil, nil, false),
        ]
        for (title, category, hour, minutes, done) in samples {
            let task = TaskItem(title: title, category: category,
                                plannedAt: hour.map { DayClock.at(hour: $0, minute: 0) },
                                durationMinutes: minutes, source: .manual)
            if title.hasPrefix("JIRA") {
                task.linkTitle = "JIRA-120 · Not3"; task.linkURL = "https://example.atlassian.net/browse/JIRA-120"
                task.statusRaw = TaskStatus.doing.rawValue
                task.reopenedAt = Date(); task.reopenedReason = "JIRA-120 → In Progress"
            }
            if title.hasPrefix("Review PR") { task.linkTitle = "Review PR #42 · app-ios"; task.linkURL = "https://github.com/example/app-ios/pull/42" }
            context.insert(task)
            if done { task.status = .done }
        }
        try? context.save()
    }
    #endif

    /// App-bar refresh on "Hôm nay": ask the server to pull GitHub / Jira first, then the usual pass.
    static func refreshNow() async {
        let context = Persistence.shared.mainContext
        await SupabaseService.shared.syncIntegrationsNow(context)
        await onForeground()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BackgroundRefresh.register()
        return true
    }

    /// Silent push (`content-available`) from the server after GitHub / Jira changed something:
    /// refresh data and widgets in the background.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await AppLifecycle.backgroundRefresh()
        return .newData
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await SupabaseService.shared.registerDevice(token: token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator / no push entitlement: the local 12:00 fallback covers this.
    }

    /// In the app: FYI pushes go quietly to the list; a check-in already on screen is not repeated.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        if content.interruptionLevel == .passive { return [.list] }
        if content.categoryIdentifier == NotificationService.checkInCategory,
           await MainActor.run(body: { Router.shared.isCheckInPresented }) {
            return []
        }
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let taskId = (content.userInfo[NotificationService.taskIdKey] as? String).flatMap(UUID.init(uuidString:))
        let link = (content.userInfo[NotificationService.linkKey] as? String).flatMap(URL.init(string:))
        let external = (content.userInfo[NotificationService.urlKey] as? String).flatMap(URL.init(string:))
        await handle(action: action, category: category, taskId: taskId, link: link, external: external)
    }

    @MainActor
    private func handle(action: String, category: String, taskId: UUID?, link: URL?, external: URL?) async {
        let context = Persistence.shared.mainContext
        let supabase = SupabaseService.shared

        // Tap on the notification body: open where it points (the task, check-in, summary).
        if action == UNNotificationDefaultActionIdentifier {
            if let link {
                Router.shared.open(link)
            } else if category == NotificationService.checkInCategory {
                Router.shared.openCheckIn()
            } else if let taskId {
                Router.shared.open(URL(string: "not3://task/\(taskId.uuidString)")!)
            }
            return
        }
        if action == NotificationService.openExternalAction {
            if let external { await UIApplication.shared.open(external) }
            if let taskId { Router.shared.focusTaskId = taskId }
            return
        }
        if category == NotificationService.eveningCategory, let taskId {
            await TaskActions.handleEvening(
                action: action, taskId: taskId, in: context, serverPushActive: supabase.hasServerPush
            )
            await supabase.syncPending(context)
            WidgetBridge.publish()
            return
        }
        if category == NotificationService.reminderCategory, let taskId {
            // A server task may not be on this device yet: pull first.
            if TaskActions.task(id: taskId, in: context) == nil { await supabase.pullTaskUpdates(context) }
            await TaskActions.handleReminder(
                action: action, taskId: taskId, in: context, serverPushActive: supabase.hasServerPush
            )
            await supabase.syncPending(context)
            WidgetBridge.publish()
            return
        }
        if action.hasPrefix(NotificationService.moodActionPrefix),
           let mood = Mood(rawValue: String(action.dropFirst(NotificationService.moodActionPrefix.count))) {
            // Answered from the notification without opening the app.
            CheckInService.recordMood(mood, in: context)
            await SupabaseService.shared.syncPending(context)
            WidgetBridge.publish()
            return
        }
    }
}
