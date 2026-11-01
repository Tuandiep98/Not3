import Observation
import SwiftData
import SwiftUI

enum Route: Hashable {
    case today
    case summary
    case allNotes
    case folder(PersistentIdentifier)
    case note(PersistentIdentifier)
}

@MainActor
@Observable
final class Router {
    static let shared = Router()

    /// "Hôm nay" opens by default, with "Thư mục" underneath like Apple Notes' last-folder behaviour.
    var path: [Route] = [.today]
    var isCheckInPresented = false

    func openCheckIn() {
        if path.last != .today { path = [.today] }
        isCheckInPresented = true
    }
}
