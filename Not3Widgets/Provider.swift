import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var folderID: UUID = WidgetSnapshot.allNotesID
}

/// Timelines from the App Group snapshot. Entries sit on the moments the content changes on its own
/// (check-in time, midnight); everything else is pushed by the app via reloadAllTimelines().
enum Timelines {
    static func entries(_ snapshot: WidgetSnapshot, now: Date = Date(), folderID: UUID = WidgetSnapshot.allNotesID) -> Timeline<SnapshotEntry> {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
        var dates = [now, midnight]
        let checkIn = snapshot.checkInTime(on: now)
        if checkIn > now { dates.append(checkIn) }
        // Planned tasks: the "next" one changes as each start time passes.
        dates += snapshot.tasks.compactMap(\.plannedAt).filter { $0 > now && $0 < midnight }
        let entries = Set(dates).sorted().map { SnapshotEntry(date: $0, snapshot: snapshot, folderID: folderID) }
        // Re-read at least every 30 min in case a background refresh was missed.
        return Timeline(entries: entries, policy: .after(min(midnight, now.addingTimeInterval(30 * 60))))
    }

    static let preview: WidgetSnapshot = {
        let now = Date()
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: now)! }
        return WidgetSnapshot(
            generatedAt: now, day: cal.startOfDay(for: now), checkInHour: 12, checkInMinute: 0,
            mood: nil, checkInAt: nil, plan: nil,
            morning: [
                .init(id: "1", title: "Review PR #42 · app-ios", source: "github", time: at(9, 5), url: nil),
                .init(id: "2", title: "Họp sprint 09:30", source: "calendar", time: at(9, 30), url: nil),
                .init(id: "3", title: "JIRA-118 → Done", source: "jira", time: at(10, 40), url: nil),
            ],
            tasks: [
                .init(id: UUID(), title: "Học 20 từ vựng Anki", status: "todo", plannedAt: at(14), durationMinutes: 25, source: nil, reopenedReason: nil, createdAt: now),
                .init(id: UUID(), title: "Viết test module login", status: "todo", plannedAt: at(16, 30), durationMinutes: 45, source: "github", reopenedReason: nil, createdAt: now),
                .init(id: UUID(), title: "JIRA-120: Push 12h", status: "doing", plannedAt: nil, durationMinutes: nil, source: "jira", reopenedReason: "JIRA-120 → In Progress", createdAt: now),
            ],
            week: [true, true, false, true, true, false, false],
            folders: [.init(id: WidgetSnapshot.allNotesID, name: "Học ngôn ngữ", notes: [
                .init(id: UUID(), title: "Từ vựng tuần 44", preview: "commitment, deploy", updatedAt: now),
                .init(id: UUID(), title: "Phỏng vấn", preview: "Tell me about a project", updatedAt: now),
                .init(id: UUID(), title: "Ngữ pháp", preview: "have/has + V3", updatedAt: now),
                .init(id: UUID(), title: "Từ vựng tuần 43", preview: "sprint, backlog", updatedAt: now),
            ])]
        )
    }()
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: Timelines.preview) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = WidgetSnapshot.load()
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview && snapshot.generatedAt == .distantPast ? Timelines.preview : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timelines.entries(WidgetSnapshot.load()))
    }
}

struct FolderProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: Timelines.preview) }

    func snapshot(for configuration: SelectFolderIntent, in context: Context) async -> SnapshotEntry {
        let snapshot = WidgetSnapshot.load()
        return SnapshotEntry(date: Date(), snapshot: context.isPreview && snapshot.folders.isEmpty ? Timelines.preview : snapshot,
                             folderID: configuration.folder?.id ?? WidgetSnapshot.allNotesID)
    }

    func timeline(for configuration: SelectFolderIntent, in context: Context) async -> Timeline<SnapshotEntry> {
        Timelines.entries(WidgetSnapshot.load(), folderID: configuration.folder?.id ?? WidgetSnapshot.allNotesID)
    }
}
