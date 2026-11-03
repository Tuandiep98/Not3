import AppIntents
import WidgetKit

// Interactive widget actions. They update the snapshot right away (the widget re-renders) and
// queue the change for the app, which applies it to SwiftData and syncs on its next run.

struct ToggleTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Đánh dấu việc"
    static let isDiscoverable = false

    @Parameter(title: "Việc") var taskID: String
    @Parameter(title: "Xong") var done: Bool

    init() {}
    init(taskID: UUID, done: Bool) {
        self.taskID = taskID.uuidString
        self.done = done
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { return .result() }
        WidgetAction(kind: .setTaskDone, taskId: id, done: done).applyToSnapshotAndEnqueue()
        return .result()
    }
}

struct StartTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Bắt đầu việc"
    static let isDiscoverable = false

    @Parameter(title: "Việc") var taskID: String

    init() {}
    init(taskID: UUID) { self.taskID = taskID.uuidString }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { return .result() }
        WidgetAction(kind: .startTask, taskId: id).applyToSnapshotAndEnqueue()
        return .result()
    }
}

struct RecordMoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Cảm nhận buổi sáng"
    static let isDiscoverable = false

    @Parameter(title: "Cảm nhận") var mood: String

    init() {}
    init(mood: String) { self.mood = mood }

    func perform() async throws -> some IntentResult {
        WidgetAction(kind: .recordMood, mood: mood).applyToSnapshotAndEnqueue()
        return .result()
    }
}

// MARK: Folder picker for the "Thư mục ghi chú" widget

struct FolderEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Thư mục"
    static let defaultQuery = FolderQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static let allNotes = FolderEntity(id: WidgetSnapshot.allNotesID, name: "Tất cả ghi chú")
}

struct FolderQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [FolderEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FolderEntity] {
        let folders = WidgetSnapshot.load().folders.map { FolderEntity(id: $0.id, name: $0.name) }
        return folders.isEmpty ? [.allNotes] : folders
    }

    func defaultResult() async -> FolderEntity? { .allNotes }
}

struct SelectFolderIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Chọn thư mục"
    static let description = IntentDescription("Hiện các ghi chú mới nhất của một thư mục.")

    @Parameter(title: "Thư mục") var folder: FolderEntity?
}
