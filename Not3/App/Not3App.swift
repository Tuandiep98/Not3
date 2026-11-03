import CoreSpotlight
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
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // Spotlight result → the note / task it points to.
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let url = SpotlightIndexer.deepLink(for: id) {
                        Router.shared.open(url)
                    }
                }
        }
        .modelContainer(Persistence.shared)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                AppLock.shared.didBecomeActive()
                Task { await AppLifecycle.onForeground() }
            case .inactive:
                AppLock.shared.willResignActive()
            case .background:
                AppLock.shared.didEnterBackground()
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
        RemindersService.shared.startObserving()
        WidgetBridge.startObserving()
        SpotlightIndexer.startObserving()
        WatchBridge.shared.start()
        NotificationService.registerCategories()
        // Permission is asked in context (first check-in save), not on first launch.
        UIApplication.shared.registerForRemoteNotifications()
        await SupabaseService.shared.restoreSession()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-openCheckIn") { Router.shared.openCheckIn() }
        if args.contains("-openShutdown") { Router.shared.openShutdown() }
        if args.contains("-openFolders") { Router.shared.path = [] }
        if args.contains("-openSummary") { Router.shared.path = [.summary] }
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
        await NotificationService.rescheduleShutdown(in: context)
        await CalendarService.shared.refresh(in: context)
        // Lời nhắc / Sức khỏe, when turned on (on device only).
        await LocalModule.refreshAll(in: context)
        // Today's occurrences of repeating tasks, before they sync.
        await RecurrenceService.generate(in: context, serverPushActive: supabase.hasServerPush)
        await supabase.syncPending(context)
        await supabase.uploadCalendarItems(context)
        await supabase.pullContentRules()
        await supabase.pullExternalItems(context)
        await supabase.pullTaskUpdates(context)
        await supabase.pullLinks(context)
        await supabase.pullCards(context)
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
        // Lời nhắc / Sức khỏe, when turned on (on device only).
        await LocalModule.refreshAll(in: context)
        // Today's occurrences of repeating tasks, before they sync.
        await RecurrenceService.generate(in: context, serverPushActive: supabase.hasServerPush)
        await supabase.syncPending(context)
        await supabase.uploadCalendarItems(context)
        await supabase.pullContentRules()
        await supabase.pullExternalItems(context)
        await supabase.pullTaskUpdates(context)
        await supabase.pullLinks(context)
        await supabase.pullCards(context)
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
        // A Jira work log in "Buổi sáng": its comment + the time spent chip.
        let worklog = ExternalItem(source: .jira, externalId: "worklog:sample", title: "Review API đăng nhập với team backend",
                                   url: "https://example.atlassian.net/browse/JIRA-120", occurredAt: DayClock.at(hour: 9, minute: 30))
        worklog.kind = "worklog"; worklog.status = "done"; worklog.decision = "journal"; worklog.durationSeconds = 5400
        context.insert(worklog)
        try? context.save()
    }
    #endif

    /// Pull to refresh on "Hôm nay": ask the server to pull GitHub / Jira first, then the usual pass.
    /// Returns what could not be synced ("Jira: Cần đăng nhập lại"), or nil.
    @discardableResult
    static func refreshNow() async -> String? {
        let context = Persistence.shared.mainContext
        let problem = await SupabaseService.shared.syncIntegrationsNow(context)
        await onForeground()
        return problem
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
    // Completion-handler variants, called back on the main thread: with the `async` variants a
    // nonisolated method finishes on the cooperative pool, so iOS's completion handler ran off
    // main and UIKit aborted (-[UIApplication _updateSnapshotAndStateRestorationWithAction:]).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        let passive = content.interruptionLevel == .passive
        let category = content.categoryIdentifier
        Task { @MainActor in
            if passive { return completionHandler([.list]) }
            if category == NotificationService.checkInCategory, Router.shared.isCheckInPresented {
                return completionHandler([])
            }
            if category == NotificationService.shutdownCategory, Router.shared.isShutdownPresented {
                return completionHandler([])
            }
            completionHandler([.banner, .sound, .list])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let taskId = (content.userInfo[NotificationService.taskIdKey] as? String).flatMap(UUID.init(uuidString:))
        let link = (content.userInfo[NotificationService.linkKey] as? String).flatMap(URL.init(string:))
        let external = (content.userInfo[NotificationService.urlKey] as? String).flatMap(URL.init(string:))
        Task { @MainActor in
            await self.handle(action: action, category: category, taskId: taskId, link: link, external: external)
            completionHandler()
        }
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
            // Back in the app, "Hôm nay" shows the task, as a tap on the body would.
            if let target = link ?? taskId.flatMap({ URL(string: "not3://task/\($0.uuidString)") }) {
                Router.shared.open(target)
            }
            if let external { await UIApplication.shared.open(external) }
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
        if action == NotificationService.shutdownTomorrowAction {
            await TaskActions.closeDayMovingRest(in: context, serverPushActive: supabase.hasServerPush)
            try? context.save()
            await NotificationService.rescheduleShutdown(in: context)
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
