import Foundation
import WatchConnectivity

/// iPhone side of the watch app. The watch gets the same snapshot as the widgets
/// (application context: only the latest one is kept); the watch sends back `WidgetAction`s,
/// which go through the widgets' queue and `WidgetBridge.applyPendingActions`.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    nonisolated static let snapshotKey = "snapshot"
    nonisolated static let actionKey = "action"

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func start() {
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    /// Called whenever the widgets' snapshot changes.
    func send(_ snapshot: WidgetSnapshot) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder.widget.encode(snapshot) else { return }
        try? session.updateApplicationContext([Self.snapshotKey: data])
    }

    fileprivate func receive(_ data: Data?) {
        guard let data, let action = try? JSONDecoder.widget.decode(WidgetAction.self, from: data) else { return }
        action.enqueue()
        Task {
            await WidgetBridge.applyPendingActions(serverPushActive: SupabaseService.shared.hasServerPush)
            WidgetBridge.publish()
            await SupabaseService.shared.syncPending(Persistence.shared.mainContext)
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        Task { @MainActor in WatchBridge.shared.send(WidgetSnapshot.load()) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switched to another watch: activate again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let data = userInfo[WatchBridge.actionKey] as? Data
        Task { @MainActor in WatchBridge.shared.receive(data) }
    }

    /// Sent while reachable: wakes the app in the background. The reply is the snapshot with the
    /// action already shown; the real one follows as application context once the app applied it.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let data = message[WatchBridge.actionKey] as? Data
        var snapshot = WidgetSnapshot.load()
        if let data, let action = try? JSONDecoder.widget.decode(WidgetAction.self, from: data) { snapshot.apply(action) }
        replyHandler([WatchBridge.snapshotKey: (try? JSONEncoder.widget.encode(snapshot)) ?? Data()])
        Task { @MainActor in WatchBridge.shared.receive(data) }
    }
}
