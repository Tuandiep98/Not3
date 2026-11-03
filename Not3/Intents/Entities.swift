import AppIntents
import CoreSpotlight
import Foundation
import SwiftData

// Tasks and notes for Shortcuts, Siri and Spotlight. Read straight from SwiftData: these only run
// in the app process (Not3/Intents is not part of the widget extension).

struct TaskEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Việc"
    static let defaultQuery = TaskEntityQuery()

    let id: UUID
    let title: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }

    @MainActor
    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        detail = TaskEntity.detail(for: task)
    }

    /// "Hôm nay 14:00 · 25 phút · Công việc", "Hộp chờ · Đọc sách".
    @MainActor
    static func detail(for task: TaskItem, now: Date = Date()) -> String {
        let when: String
        if task.isSomeday {
            when = "Hộp chờ"
        } else if let planned = task.plannedAt {
            when = DayClock.calendar.isDate(planned, inSameDayAs: now)
                ? "Hôm nay \(DayClock.time(planned))"
                : "\(DayClock.dayMonth(planned)) \(DayClock.time(planned))"
        } else {
            when = "Hôm nay"
        }
        let status = task.status == .doing ? TaskStatus.doing.label : nil
        return [when, status, task.durationMinutes.map { "\($0) phút" }, task.category]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct TaskEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [TaskEntity] {
        await MainActor.run {
            let context = Persistence.shared.mainContext
            return identifiers.compactMap { TaskActions.task(id: $0, in: context) }.map(TaskEntity.init)
        }
    }

    /// Open work of today, then the "Hộp chờ".
    func suggestedEntities() async throws -> [TaskEntity] {
        await MainActor.run {
            // No task names in Siri / Shortcuts pickers on a locked iPhone.
            guard !IntentPrivacy.isRestricted else { return [] }
            let all = TaskEntityQuery.allTasks()
            let open = TodayList.tasks(all).filter { $0.status != .done } + TodayList.backlog(all)
            return open.map(TaskEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [TaskEntity] {
        await MainActor.run {
            guard !IntentPrivacy.isRestricted else { return [] }
            return TaskEntityQuery.allTasks()
                .filter { ($0.status == .todo || $0.status == .doing) && $0.title.localizedStandardContains(string) }
                .map(TaskEntity.init)
        }
    }

    @MainActor
    static func allTasks() -> [TaskItem] {
        (try? Persistence.shared.mainContext.fetch(FetchDescriptor<TaskItem>())) ?? []
    }
}

struct NoteEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Ghi chú"
    static let defaultQuery = NoteEntityQuery()

    let id: UUID
    let title: String
    let preview: String
    let folder: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\([folder, preview].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))")
    }

    @MainActor
    init(_ note: Note) {
        id = note.id
        title = note.displayTitle
        preview = note.preview
        folder = note.folder?.name
    }
}

struct NoteEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [NoteEntity] {
        await MainActor.run {
            NoteEntityQuery.notes().filter { identifiers.contains($0.id) }.map(NoteEntity.init)
        }
    }

    func suggestedEntities() async throws -> [NoteEntity] {
        await MainActor.run {
            guard !IntentPrivacy.isRestricted else { return [] }
            return NoteEntityQuery.notes().prefix(10).map(NoteEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [NoteEntity] {
        await MainActor.run {
            guard !IntentPrivacy.isRestricted else { return [] }
            return NoteEntityQuery.notes()
                .filter { $0.title.localizedStandardContains(string) || $0.body.localizedStandardContains(string) }
                .map(NoteEntity.init)
        }
    }

    /// Non-empty notes, most recently edited first.
    @MainActor
    static func notes() -> [Note] {
        let all = (try? Persistence.shared.mainContext.fetch(
            FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )) ?? []
        return all.filter { !$0.title.isEmpty || !$0.body.isEmpty || !($0.checklist ?? []).isEmpty }
    }
}
