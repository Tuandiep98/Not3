import Foundation
import WatchConnectivity
import WidgetKit

/// Watch side: shows the iPhone's snapshot (kept in the watch's App Group for complications) and
/// sends actions back. Changes show at once; the iPhone's next snapshot confirms them.
@MainActor
@Observable
final class WatchStore: NSObject {
    static let shared = WatchStore()

    nonisolated static let snapshotKey = "snapshot"
    nonisolated static let actionKey = "action"

    private(set) var snapshot = WidgetSnapshot.load()

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func perform(_ action: WidgetAction) {
        snapshot.apply(action)
        store(snapshot)
        guard let data = try? JSONEncoder.widget.encode(action) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            // Not connected yet: queue it; delivered once the session is up.
            session.transferUserInfo([Self.actionKey: data])
            return
        }
        if session.isReachable {
            // Wakes the iPhone app in the background; the reply is the updated snapshot.
            session.sendMessage([Self.actionKey: data], replyHandler: { reply in
                let snapshot = reply[WatchStore.snapshotKey] as? Data
                Task { @MainActor in WatchStore.shared.receive(snapshot) }
            }, errorHandler: { _ in
                WCSession.default.transferUserInfo([WatchStore.actionKey: data])
            })
        } else {
            session.transferUserInfo([Self.actionKey: data])
        }
    }

    fileprivate func receive(_ data: Data?) {
        guard let data, let new = try? JSONDecoder.widget.decode(WidgetSnapshot.self, from: data) else { return }
        store(new)
    }

    private func store(_ new: WidgetSnapshot) {
        snapshot = new
        new.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext[WatchStore.snapshotKey] as? Data
        Task { @MainActor in WatchStore.shared.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WatchStore.snapshotKey] as? Data
        Task { @MainActor in WatchStore.shared.receive(data) }
    }
}
