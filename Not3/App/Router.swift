import Observation
import SwiftData
import SwiftUI

enum Route: Hashable {
    case today
    case backlog
    case summary
    case activityDay(Date)
    case activityHistory
    case activityMethod
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
    /// Task to scroll to and flash in "Hôm nay" (opened from a notification or widget).
    var focusTaskId: UUID?
    /// Task editor sheet: a new task or an existing one.
    var taskEditor: TaskEditorTarget?

    func openCheckIn() {
        if path.last != .today { path = [.today] }
        isCheckInPresented = true
    }

    /// not3:// links from widgets. (not3://oauth is consumed by ASWebAuthenticationSession.)
    func open(_ url: URL) {
        guard url.scheme == "not3" else { return }
        let context = Persistence.shared.mainContext
        let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
        isCheckInPresented = false
        switch url.host() {
        case "today":
            path = [.today]
        case "task":
            // "Hộp chờ" items are not in "Hôm nay": open the backlog with the task's editor.
            if let id, let task = TaskActions.task(id: id, in: context), task.isSomeday {
                path = [.backlog]
                taskEditor = .edit(id)
            } else {
                path = [.today]
                focusTaskId = id
            }
        case "checkin":
            openCheckIn()
        case "backlog":
            path = [.backlog]
        case "new-task":
            if path.last != .today && path.last != .backlog { path = [.today] }
            taskEditor = .new(someday: path.last == .backlog)
        case "summary":
            path = [.summary]
        case "folder":
            if let id, id != WidgetSnapshot.allNotesID,
               let folder = try? context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })).first {
                path = [.folder(folder.persistentModelID)]
            } else {
                path = [.allNotes]
            }
        case "note":
            if let id, let note = try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first {
                path = [.allNotes, .note(note.persistentModelID)]
            }
        case "new-note":
            let folderId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "folder" }?.value.flatMap(UUID.init(uuidString:))
            let folder = folderId.flatMap { fid in
                try? context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.id == fid })).first
            }
            let note = Note(folder: folder)
            context.insert(note)
            path = [folder.map { .folder($0.persistentModelID) } ?? .allNotes, .note(note.persistentModelID)]
        default:
            break
        }
    }
}

/// What the task editor sheet opens on.
enum TaskEditorTarget: Identifiable, Hashable {
    case new(someday: Bool)
    case edit(UUID)

    var id: String {
        switch self {
        case .new(let someday): "new|\(someday)"
        case .edit(let id): id.uuidString
        }
    }
}
