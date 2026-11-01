import Foundation
import SwiftData

/// "Nhật ký hôm nay" (README §12): one note per day in the "Nhật ký" folder, split Sáng / Chiều,
/// filled with finished tasks, PRs, tickets and meetings. The app only rewrites the managed block
/// between the two markers — anything the user types outside it is never touched.
@MainActor
enum JournalService {
    static let folderName = "Nhật ký"
    static let beginMarker = "— Tự động —"
    static let endMarker = "— Hết phần tự động —"

    struct Entry: Equatable {
        let time: Date
        let text: String
    }

    static func updateToday(in context: ModelContext, now: Date = Date()) {
        let entries = collect(in: context, now: now)
        guard !entries.isEmpty else { return }
        let block = render(entries, now: now)
        let note = todaysNote(in: context, now: now) ?? createNote(in: context, now: now)
        let merged = replaceManagedBlock(in: note.body, with: block)
        if merged != note.body {
            note.body = merged
            note.updatedAt = now
            note.needsSync = true
        }
        try? context.save()
    }

    // MARK: Content

    static func collect(in context: ModelContext, now: Date) -> [Entry] {
        let start = DayClock.startOfDay(now)
        let end = DayClock.endOfDay(now)
        let done = TaskStatus.done.rawValue
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.statusRaw == done && $0.completedAt != nil
        }))) ?? []
        var entries = tasks.compactMap { task -> Entry? in
            guard let at = task.completedAt, at >= start, at < end else { return nil }
            return Entry(time: at, text: "✓ \(task.title)")
        }
        let items = (try? context.fetch(FetchDescriptor<ExternalItem>(predicate: #Predicate {
            $0.occurredAt >= start && $0.occurredAt < end
        }))) ?? []
        // Upcoming calendar events are not "done" yet.
        entries += items.filter { $0.source != .calendar || $0.occurredAt <= now }.map {
            Entry(time: $0.occurredAt, text: "\($0.source.label): \($0.title)")
        }
        return entries.sorted { $0.time < $1.time }
    }

    static func render(_ entries: [Entry], now: Date) -> String {
        let noon = DayClock.noon(now)
        let morning = entries.filter { $0.time < noon }
        let afternoon = entries.filter { $0.time >= noon }
        var lines = [beginMarker]
        for (title, group) in [("Sáng", morning), ("Chiều", afternoon)] where !group.isEmpty {
            lines.append(title)
            lines += group.map { "\(DayClock.time($0.time))  \($0.text)" }
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// Swaps the text between the markers; appends the block when the note has none yet.
    static func replaceManagedBlock(in body: String, with block: String) -> String {
        if let begin = body.range(of: beginMarker),
           let end = body.range(of: endMarker, range: begin.upperBound..<body.endIndex) {
            return body.replacingCharacters(in: begin.lowerBound..<end.upperBound, with: block)
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? block : body + "\n\n" + block
    }

    // MARK: Note

    static func title(for date: Date) -> String {
        "Nhật ký \(DayClock.dayMonth(date))"
    }

    private static func folder(in context: ModelContext) -> Folder {
        let name = folderName
        if let existing = try? context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.name == name })).first {
            return existing
        }
        let count = (try? context.fetchCount(FetchDescriptor<Folder>())) ?? 0
        let folder = Folder(name: name, sortOrder: count)
        context.insert(folder)
        return folder
    }

    private static func todaysNote(in context: ModelContext, now: Date) -> Note? {
        let title = title(for: now)
        let start = DayClock.startOfDay(now)
        return try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate {
            $0.title == title && $0.createdAt >= start
        })).first
    }

    private static func createNote(in context: ModelContext, now: Date) -> Note {
        let note = Note(folder: folder(in: context))
        note.title = title(for: now)
        note.createdAt = now
        context.insert(note)
        return note
    }
}
