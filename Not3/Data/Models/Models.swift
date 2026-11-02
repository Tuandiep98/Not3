import Foundation
import SwiftData

// Local SwiftData models. Supabase is the source of truth for tasks, check-ins and chips
// (see README §7); SwiftData is the offline cache + write-ahead store.
// Every property has a default and relationships are optional so the store stays CloudKit-compatible.

enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case todo, doing, done, cancelled

    var label: String {
        switch self {
        case .todo: "Chưa làm"
        case .doing: "Đang làm"
        case .done: "Xong"
        case .cancelled: "Đã huỷ"
        }
    }
}

enum TaskSource: String, Codable, Sendable {
    case manual, ai, integration
}

enum Mood: String, Codable, CaseIterable, Identifiable, Sendable {
    case good, ok, empty

    var id: String { rawValue }

    var label: String {
        switch self {
        case .good: "Hiệu quả"
        case .ok: "Bình thường"
        case .empty: "Trống"
        }
    }
}

enum ChipGroup: String, Codable, Sendable {
    case category, duration, time, mood, item, ai
}

enum ExternalSource: String, Codable, Sendable {
    case calendar, github, jira

    var label: String {
        switch self {
        case .calendar: "Lịch"
        case .github: "GitHub"
        case .jira: "Jira"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .github: "arrow.triangle.branch"
        case .jira: "ticket"
        }
    }

    /// Source of a linked task, from its URL (github.com / *.atlassian.net).
    init?(linkURL: String?) {
        guard let host = linkURL.flatMap(URL.init(string:))?.host()?.lowercased() else { return nil }
        if host == "github.com" || host.hasSuffix(".github.com") {
            self = .github
        } else if host.hasSuffix("atlassian.net") || host.contains("jira") {
            self = .jira
        } else {
            return nil
        }
    }
}

@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    var notes: [Note]? = []

    init(name: String, sortOrder: Int) {
        self.name = name
        self.sortOrder = sortOrder
    }
}

@Model
final class Note {
    var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var categories: [String] = []
    /// Chips suggested by AI (`tag-note`); shown in the editor until accepted or dismissed.
    var suggestedCategories: [String] = []
    var durationMinutes: Int?
    var isPinned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var needsSync: Bool = true
    var folder: Folder?
    @Relationship(deleteRule: .cascade, inverse: \ChecklistItem.note)
    var checklist: [ChecklistItem]? = []

    init(folder: Folder?) {
        self.folder = folder
    }

    var sortedChecklist: [ChecklistItem] {
        (checklist ?? []).sorted { $0.order < $1.order }
    }

    /// Text shown under the title in lists (first body line or checklist items).
    var preview: String {
        let lines = body.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if let first = lines.first { return first }
        return sortedChecklist.map(\.text).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? "Ghi chú mới" : title
    }
}

@Model
final class ChecklistItem {
    var id: UUID = UUID()
    var text: String = ""
    var isDone: Bool = false
    var order: Int = 0
    var note: Note?

    init(text: String, order: Int) {
        self.text = text
        self.order = order
    }
}

@Model
final class TaskItem {
    var id: UUID = UUID()
    var title: String = ""
    var category: String?
    var plannedAt: Date?
    var durationMinutes: Int?
    var statusRaw: String = TaskStatus.todo.rawValue
    var sourceRaw: String = TaskSource.manual.rawValue
    /// "Lúc 14:00, mình sẽ … trong 25 phút."
    var ifThenSentence: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var completedAt: Date?
    /// When it went to "đang làm" (Bắt đầu): with completedAt, the real time spent.
    var startedAt: Date?
    var calendarEventId: String?
    var needsSync: Bool = true
    /// Linked PR / ticket (server `task_links`), shown as a badge that opens the original.
    var linkTitle: String?
    var linkURL: String?
    /// AI link suggestion waiting for one tap ("Liên kết với PR #57?").
    var linkSuggestionId: UUID?
    var linkSuggestionTitle: String?
    /// Set by the server when GitHub / Jira sent finished work back (rejected review, ticket moved
    /// back from Code Review…): the task is unticked and shows why.
    var reopenedAt: Date?
    var reopenedReason: String?

    init(title: String, category: String?, plannedAt: Date?, durationMinutes: Int?, source: TaskSource) {
        self.title = title
        self.category = category
        self.plannedAt = plannedAt
        self.durationMinutes = durationMinutes
        self.sourceRaw = source.rawValue
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .todo }
        set {
            statusRaw = newValue.rawValue
            completedAt = newValue == .done ? Date() : nil
            switch newValue {
            case .doing: if startedAt == nil { startedAt = Date() }
            case .todo, .cancelled: startedAt = nil
            case .done: break
            }
            touch()
        }
    }

    var source: TaskSource { TaskSource(rawValue: sourceRaw) ?? .manual }

    func touch() {
        updatedAt = Date()
        needsSync = true
    }
}

@Model
final class CheckIn {
    var id: UUID = UUID()
    /// Start of the local day this check-in belongs to.
    var day: Date = Date()
    var morningItems: [String] = []
    var moodRaw: String?
    var afternoonTaskIds: [UUID] = []
    var createdAt: Date = Date()
    var needsSync: Bool = true

    init(day: Date) {
        self.day = day
    }

    var mood: Mood? {
        get { moodRaw.flatMap(Mood.init(rawValue:)) }
        set { moodRaw = newValue?.rawValue; needsSync = true }
    }
}

@Model
final class Chip {
    var id: UUID = UUID()
    var groupRaw: String = ChipGroup.category.rawValue
    var label: String = ""
    var useCount: Int = 0
    var lastUsedAt: Date?
    var isBuiltIn: Bool = false

    init(group: ChipGroup, label: String, isBuiltIn: Bool) {
        self.groupRaw = group.rawValue
        self.label = label
        self.isBuiltIn = isBuiltIn
    }

    var group: ChipGroup { ChipGroup(rawValue: groupRaw) ?? .category }
}

/// Items pulled from GitHub / Jira / Calendar (filled by sync in phase 3).
@Model
final class ExternalItem {
    var id: UUID = UUID()
    var sourceRaw: String = ExternalSource.calendar.rawValue
    var externalId: String = ""
    var title: String = ""
    var url: String?
    var occurredAt: Date = Date()
    /// Provider state: merged / review_requested / done / in_progress… (nil for calendar).
    var status: String?
    var kind: String?
    /// Server classification: nil = "chưa phân loại" (warning row); task / note / ignored / journal.
    var decision: String?
    /// The user's part: author / assignee / reviewer / reporter / involved.
    var role: String?
    /// owner/repo or Jira project key.
    var scope: String?

    init(source: ExternalSource, externalId: String, title: String, url: String?, occurredAt: Date) {
        self.sourceRaw = source.rawValue
        self.externalId = externalId
        self.title = title
        self.url = url
        self.occurredAt = occurredAt
    }

    var source: ExternalSource { ExternalSource(rawValue: sourceRaw) ?? .calendar }

    /// Why the server could not classify it (mirrors supabase/functions/_shared/classify.ts).
    var unclassifiedReason: String {
        switch (source, kind, role) {
        case (.jira, _, "reporter"): "Bạn tạo ticket, người khác làm"
        case (.jira, _, "watcher"): "Bạn đang theo dõi ticket"
        case (.github, "issue", "author"): "Issue bạn tạo, chưa giao cho ai"
        case (_, _, "involved"): "Bạn chỉ được nhắc đến"
        default: "Chưa rõ việc của bạn trong mục này"
        }
    }

    /// Repo / project name for "Luôn bỏ qua từ …".
    var scopeLabel: String? {
        guard let scope, !scope.isEmpty else { return nil }
        return scope.split(separator: "/").last.map(String.init)
    }
}
