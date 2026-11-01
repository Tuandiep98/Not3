import BackgroundTasks
import Foundation

/// Periodic background refresh (~every 30 min, at iOS's discretion): pulls GitHub / Jira / Calendar,
/// applies widget actions, syncs, and republishes the widget snapshot. Silent pushes from the server
/// (sent when GitHub / Jira change a task) run the same pass right away.
enum BackgroundRefresh {
    static let identifier = "com.tuandiep.not3.refresh"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()   // keep the chain going
        let box = TaskBox(task)
        let work = Task { @MainActor in
            await AppLifecycle.backgroundRefresh()
            box.complete(true)
        }
        task.expirationHandler = {
            work.cancel()
            box.complete(false)
        }
    }
}

/// BGTask is not Sendable; it is only touched to complete it, exactly once.
private final class TaskBox: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var done = false

    init(_ task: BGTask) { self.task = task }

    func complete(_ success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        task.setTaskCompleted(success: success)
    }
}
