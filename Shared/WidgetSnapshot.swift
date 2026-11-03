import Foundation

// Shared by the app and the widget extension.
// The app writes a small JSON snapshot into the App Group; widgets only read it (fast, no SwiftData
// or CloudKit in the extension). Interactive widgets record actions as one file each in the App
// Group; the app applies them (and syncs) on its next run, foreground or background.

enum AppGroup {
    static let id = "group.com.tuandiep.not3"

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.temporaryDirectory  // unsigned simulator builds: no App Group
    }

    static var snapshotURL: URL { container.appending(path: "widget-snapshot.json") }
    static var actionsDirectory: URL { container.appending(path: "widget-actions", directoryHint: .isDirectory) }
}

enum WidgetKind {
    static let checkIn = "Not3CheckIn"
    static let today = "Not3Today"
    static let week = "Not3Week"
    static let folder = "Not3Folder"
    static let newTaskControl = "Not3NewTaskControl"
    static let checkInControl = "Not3CheckInControl"
    static let nextTaskControl = "Not3NextTaskControl"
}

struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        var source: String?          // github / jira / calendar / nil = task done in the app
        var time: Date
        var url: String?
    }

    struct TaskRow: Codable, Equatable, Hashable, Sendable, Identifiable {
        var id: UUID
        var title: String
        var status: String           // todo / doing / done
        var plannedAt: Date?
        var durationMinutes: Int?
        var source: String?          // github / jira when linked
        var reopenedReason: String?
        var createdAt: Date

        var isDone: Bool { status == "done" }
    }

    struct Plan: Codable, Equatable, Sendable {
        var taskId: UUID
        var title: String
        var sentence: String
        var plannedAt: Date?
        var durationMinutes: Int?
        var status: String
    }

    struct NoteRow: Codable, Equatable, Hashable, Sendable, Identifiable {
        var id: UUID
        var title: String
        var preview: String
        var updatedAt: Date
    }

    struct FolderRow: Codable, Equatable, Hashable, Sendable, Identifiable {
        var id: UUID                 // nil-equivalent: allNotesID = "Tất cả ghi chú"
        var name: String
        var notes: [NoteRow]
    }

    static let allNotesID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")!

    var generatedAt: Date
    var day: Date
    var checkInHour: Int
    var checkInMinute: Int
    var mood: String?                // set once checked in today
    var checkInAt: Date?
    var plan: Plan?
    var morning: [Item]              // synced today before check-in (newest last)
    var tasks: [TaskRow]             // "Việc hôm nay" (same rules as the app)
    var week: [Bool]                 // Mon…Sun: a meaningful day?
    var folders: [FolderRow]         // first = all notes

    var meaningfulDays: Int { week.filter { $0 }.count }
    var openTasks: [TaskRow] { tasks.filter { !$0.isDone } }
    /// "Việc tiếp theo": the one in progress, else the first open one.
    var nextTask: TaskRow? { openTasks.first { $0.status == "doing" } ?? openTasks.first }

    func checkInTime(on date: Date) -> Date {
        Calendar.current.date(bySettingHour: checkInHour, minute: checkInMinute, second: 0, of: date) ?? date
    }

    static let empty = WidgetSnapshot(
        generatedAt: .distantPast, day: Calendar.current.startOfDay(for: Date()), checkInHour: 12, checkInMinute: 0,
        mood: nil, checkInAt: nil, plan: nil, morning: [], tasks: [], week: Array(repeating: false, count: 7), folders: []
    )

    // MARK: Storage

    static func load() -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: AppGroup.snapshotURL),
              let snapshot = try? JSONDecoder.widget.decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    func save() {
        guard let data = try? JSONEncoder.widget.encode(self) else { return }
        try? data.write(to: AppGroup.snapshotURL, options: .atomic)
    }
}

/// An action taken on a widget, applied by the app on its next run.
struct WidgetAction: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case setTaskDone, startTask, recordMood }

    var kind: Kind
    var taskId: UUID?
    var done: Bool?
    var mood: String?
    var at: Date = Date()

    /// One file per action: the widget and the app never rewrite the same file.
    func enqueue() {
        let dir = AppGroup.actionsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.widget.encode(self) else { return }
        try? data.write(to: dir.appending(path: "\(Int(at.timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"), options: .atomic)
    }

    /// Oldest first; files are removed as they are read.
    static func drain() -> [WidgetAction] {
        let dir = AppGroup.actionsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder.widget.decode(WidgetAction.self, from: data)
        }
    }
}

/// not3:// deep links used by widgets (and handled by the app's Router).
enum DeepLink {
    static let today = URL(string: "not3://today")!
    static let checkIn = URL(string: "not3://checkin")!
    static let summary = URL(string: "not3://summary")!
    static let backlog = URL(string: "not3://backlog")!
    static let newTask = URL(string: "not3://new-task")!

    static func task(_ id: UUID) -> URL { URL(string: "not3://task/\(id.uuidString)")! }

    static func folder(_ id: UUID) -> URL { URL(string: "not3://folder/\(id.uuidString)")! }
    static func note(_ id: UUID) -> URL { URL(string: "not3://note/\(id.uuidString)")! }
    static func newNote(folder: UUID?) -> URL {
        URL(string: "not3://new-note" + (folder.map { "?folder=\($0.uuidString)" } ?? ""))!
    }
}

extension JSONEncoder {
    static let widget: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}

extension JSONDecoder {
    static let widget: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
