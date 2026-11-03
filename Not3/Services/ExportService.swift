import Foundation
import SwiftData

/// "Xuất dữ liệu": every note as Markdown (photos alongside), tasks as Markdown + JSON, check-ins
/// and repeating tasks as JSON, zipped into one file the user can save or send.
@MainActor
enum ExportService {
    static func export(in context: ModelContext, now: Date = Date()) throws -> URL {
        let name = "Not3-\(DayClock.isoDay(now))"
        let work = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        let root = work.appending(path: name)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let notes = try context.fetch(FetchDescriptor<Note>(sortBy: [SortDescriptor(\.createdAt)]))
        let tasks = try context.fetch(FetchDescriptor<TaskItem>(sortBy: [SortDescriptor(\.createdAt)]))
        let checkIns = try context.fetch(FetchDescriptor<CheckIn>(sortBy: [SortDescriptor(\.day)]))
        let series = try context.fetch(FetchDescriptor<TaskSeries>(sortBy: [SortDescriptor(\.createdAt)]))

        try writeNotes(notes, to: root)
        try write(tasksMarkdown(tasks, now: now), to: root.appending(path: "tasks.md"))
        try writeJSON(tasks.map(TaskExport.init), to: root.appending(path: "tasks.json"))
        try writeJSON(checkIns.map(CheckInExport.init), to: root.appending(path: "checkins.json"))
        try writeJSON(series.map(SeriesExport.init), to: root.appending(path: "series.json"))

        return try zip(root, named: name)
    }

    // MARK: Notes

    private static func writeNotes(_ notes: [Note], to root: URL) throws {
        let attachmentsDir = root.appending(path: "attachments")
        var takenPerFolder: [String: Set<String>] = [:]
        for note in notes where !isEmpty(note) {
            let folder = sanitized(note.folder?.name ?? "Không có thư mục")
            let dir = root.appending(path: "notes").appending(path: folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var photos: [String] = []
            for (index, attachment) in note.sortedAttachments.enumerated() {
                guard let data = attachment.data else { continue }
                try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
                let photo = "\(note.id.uuidString)-\(index + 1).jpg"
                try data.write(to: attachmentsDir.appending(path: photo))
                photos.append(photo)
            }
            var taken = takenPerFolder[folder, default: []]
            let file = fileName(note.displayTitle, taken: &taken) + ".md"
            takenPerFolder[folder] = taken
            try write(markdown(for: note, photos: photos), to: dir.appending(path: file))
        }
    }

    private static func isEmpty(_ note: Note) -> Bool {
        note.title.isEmpty && note.body.isEmpty && (note.checklist ?? []).isEmpty && (note.attachments ?? []).isEmpty
    }

    /// Front matter + title + body + checklist + photos (paths relative to notes/<folder>/).
    static func markdown(for note: Note, photos: [String] = []) -> String {
        var front = [
            "created: \(iso(note.createdAt))",
            "updated: \(iso(note.updatedAt))",
        ]
        if let folder = note.folder?.name { front.append("folder: \(yaml(folder))") }
        if !note.categories.isEmpty { front.append("tags: [\(note.categories.map(yaml).joined(separator: ", "))]") }
        if let minutes = note.durationMinutes { front.append("duration: \(minutes)") }
        if note.isPinned { front.append("pinned: true") }

        var lines = ["---"] + front + ["---", "", "# \(note.displayTitle)"]
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { lines += ["", body] }
        let items = note.sortedChecklist.filter { !$0.text.isEmpty }
        if !items.isEmpty {
            lines.append("")
            lines += items.map { "- [\($0.isDone ? "x" : " ")] \($0.text)" }
        }
        if !photos.isEmpty {
            lines.append("")
            lines += photos.map { "![](../../attachments/\($0))" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Tasks

    /// "Hộp chờ" first, then one section per day (newest first).
    static func tasksMarkdown(_ tasks: [TaskItem], now: Date = Date()) -> String {
        var lines = ["# Việc · xuất ngày \(DayClock.isoDay(now))"]
        let backlog = TodayList.backlog(tasks)
        if !backlog.isEmpty {
            lines += ["", "## Hộp chờ"] + backlog.map(taskLine)
        }
        let dated = tasks.filter { !($0.isSomeday && ($0.status == .todo || $0.status == .doing)) }
        let byDay = Dictionary(grouping: dated) { DayClock.startOfDay($0.completedAt ?? $0.plannedAt ?? $0.createdAt) }
        for day in byDay.keys.sorted(by: >) {
            let items = byDay[day, default: []].sorted { ($0.plannedAt ?? $0.createdAt) < ($1.plannedAt ?? $1.createdAt) }
            lines += ["", "## \(DayClock.isoDay(day))"] + items.map(taskLine)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func taskLine(_ task: TaskItem) -> String {
        let box = switch task.status {
        case .done: "[x]"
        case .cancelled: "[-]"
        case .todo, .doing: "[ ]"
        }
        let time = task.plannedAt.map { "\(DayClock.time($0)) " } ?? ""
        let extra = [task.status == .doing ? TaskStatus.doing.label : nil,
                     task.durationMinutes.map { "\($0) phút" }, task.category, task.linkURL]
            .compactMap { $0 }
        return "- \(box) \(time)\(task.title)" + (extra.isEmpty ? "" : " · " + extra.joined(separator: " · "))
    }

    // MARK: File names

    /// Safe on every file system: no `/ \ : * ? " < > |` or line breaks, ≤ 80 characters,
    /// "Ghi chú" when empty, " 2" / " 3"… when the name is taken.
    static func fileName(_ title: String, taken: inout Set<String>) -> String {
        let base = sanitized(title)
        var name = base
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        taken.insert(name.lowercased())
        return name
    }

    static func sanitized(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        var cleaned = title.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        cleaned = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "Ghi chú" : cleaned
    }

    // MARK: Writing

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// NSFileCoordinator's `.forUploading` hands back a zip of a directory: no zip library needed.
    private static func zip(_ directory: URL, named name: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(name).zip")
        try? FileManager.default.removeItem(at: destination)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
        return destination
    }

    private static func iso(_ date: Date) -> String { date.ISO8601Format() }

    /// Quoted when YAML would misread it.
    private static func yaml(_ text: String) -> String {
        let special = CharacterSet(charactersIn: ":#[]{},&*!|>'\"%@`")
        guard text.rangeOfCharacter(from: special) != nil || text != text.trimmingCharacters(in: .whitespaces) else { return text }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: JSON shapes

private struct TaskExport: Encodable {
    let id: UUID
    let title: String
    let category: String?
    let status: String
    let someday: Bool
    let plannedAt: Date?
    let durationMinutes: Int?
    let startedAt: Date?
    let completedAt: Date?
    let createdAt: Date
    let ifThen: String?
    let link: String?
    let seriesId: UUID?

    @MainActor
    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        category = task.category
        status = task.statusRaw
        someday = task.isSomeday
        plannedAt = task.plannedAt
        durationMinutes = task.durationMinutes
        startedAt = task.startedAt
        completedAt = task.completedAt
        createdAt = task.createdAt
        ifThen = task.ifThenSentence
        link = task.linkURL
        seriesId = task.seriesId
    }
}

private struct CheckInExport: Encodable {
    let day: String
    let mood: String?
    let morning: [String]
    let afternoonTaskIds: [UUID]

    @MainActor
    init(_ checkIn: CheckIn) {
        day = DayClock.isoDay(checkIn.day)
        mood = checkIn.mood?.label
        morning = checkIn.morningItems
        afternoonTaskIds = checkIn.afternoonTaskIds
    }
}

private struct SeriesExport: Encodable {
    let id: UUID
    let title: String
    let category: String?
    let rule: String
    let ruleLabel: String
    let time: String?
    let durationMinutes: Int?
    let active: Bool

    @MainActor
    init(_ series: TaskSeries) {
        id = series.id
        title = series.title
        category = series.category
        rule = series.ruleRaw
        ruleLabel = series.rule.label
        time = series.hour.map { String(format: "%02d:%02d", $0, series.minute ?? 0) }
        durationMinutes = series.durationMinutes
        active = series.isActive
    }
}
