import Foundation
import SwiftData

/// "Nhật ký hôm nay" (README §12): one note per day in the "Nhật ký" folder — a one-line summary,
/// then Sáng / Chiều with finished tasks and reminders (✓), meetings (◷) and GitHub / Jira / Sức khỏe /
/// Gợi ý nhật ký activity (•). The app only rewrites the managed block
/// between the two markers — anything the user types outside it is never touched.
@MainActor
enum JournalService {
    static let folderName = "Nhật ký"
    static let beginMarker = "— Not3 tự ghi —"
    static let endMarker = "— Hết phần tự ghi —"
    /// Markers of notes written before the new layout (still recognised and upgraded).
    static let legacyMarkers = ("— Tự động —", "— Hết phần tự động —")

    struct Entry: Equatable {
        enum Kind: Equatable {
            /// A task ticked done today.
            case task
            /// A meeting / calendar event that already happened.
            case meeting
            /// PR, commit, review, ticket… from GitHub / Jira.
            case activity(ExternalSource)
        }

        let time: Date
        let text: String
        var kind: Kind = .task

        /// One symbol per kind so the list can be skimmed: ✓ done, ◷ meeting, • activity.
        var line: String {
            switch kind {
            case .task: "✓ \(text)"
            case .meeting: "◷ \(text)"
            case .activity(let source): "• \(source.label) · \(text)"
            }
        }
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
        let doneToday = tasks.filter { ($0.completedAt ?? .distantPast) >= start && ($0.completedAt ?? .distantPast) < end }
        var entries = doneToday.map { Entry(time: $0.completedAt ?? now, text: $0.title, kind: .task) }

        // A finished task already tells the story of its PR / ticket: don't list it twice.
        let shownURLs = Set(doneToday.compactMap(\.linkURL))
        let items = (try? context.fetch(FetchDescriptor<ExternalItem>(predicate: #Predicate {
            $0.occurredAt >= start && $0.occurredAt < end
        }))) ?? []
        entries += items.compactMap { item -> Entry? in
            // Ignored items, and items that became tasks (shown once they are done), stay out.
            guard item.decision != "ignored", item.decision != "task" else { return nil }
            if let url = item.url, shownURLs.contains(url) { return nil }
            if item.source == .calendar {
                // Upcoming events are not "done" yet.
                guard item.occurredAt <= now else { return nil }
                return Entry(time: item.occurredAt, text: item.title, kind: .meeting)
            }
            // Ticked in Apple Reminders: done work, like a task.
            if item.source == .reminders { return Entry(time: item.occurredAt, text: item.title, kind: .task) }
            // Jira work log: "Review API · 30m".
            let text = item.durationSeconds.map { "\(item.title) · \(ActivityStyle.duration(seconds: $0))" } ?? item.title
            return Entry(time: item.occurredAt, text: text, kind: .activity(item.source))
        }
        return entries.sorted { $0.time < $1.time }
    }

    /// "4 việc xong · 2 cuộc họp · 3 hoạt động GitHub · 1 Jira"
    static func summary(_ entries: [Entry]) -> String {
        var parts: [String] = []
        let tasks = entries.filter { $0.kind == .task }.count
        let meetings = entries.filter { $0.kind == .meeting }.count
        if tasks > 0 { parts.append("\(tasks) việc xong") }
        if meetings > 0 { parts.append("\(meetings) cuộc họp") }
        var first = true
        for source in [ExternalSource.github, .jira, .health, .journal] {
            let count = entries.filter { $0.kind == .activity(source) }.count
            guard count > 0 else { continue }
            parts.append(first ? "\(count) hoạt động \(source.label)" : "\(count) \(source.label)")
            first = false
        }
        return parts.joined(separator: " · ")
    }

    static func render(_ entries: [Entry], now: Date) -> String {
        let noon = DayClock.noon(now)
        var lines = [beginMarker, "Hôm nay: \(summary(entries))"]
        for (title, group) in [("Sáng", entries.filter { $0.time < noon }), ("Chiều", entries.filter { $0.time >= noon })]
        where !group.isEmpty {
            lines.append("")
            lines.append("\(title.uppercased()) · \(group.count)")
            lines += group.map { "\(DayClock.time($0.time))  \($0.line)" }
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// Swaps the text between the markers; appends the block when the note has none yet.
    static func replaceManagedBlock(in body: String, with block: String) -> String {
        for (open, close) in [(beginMarker, endMarker), legacyMarkers] {
            if let begin = body.range(of: open),
               let end = body.range(of: close, range: begin.upperBound..<body.endIndex) {
                return body.replacingCharacters(in: begin.lowerBound..<end.upperBound, with: block)
            }
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
