import SwiftUI

@main
struct Not3WatchApp: App {
    init() {
        WatchStore.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchTodayView()
                .environment(WatchStore.shared)
        }
    }
}
