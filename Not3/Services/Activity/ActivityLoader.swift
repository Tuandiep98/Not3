import Foundation
import SwiftData

/// Two task categories get their own colour (purple, pink); the rest fold into "Khác". A category
/// keeps its colour for good once it has one, so colours never move between weeks.
enum ActivityCategorySlots {
    static let count = 2
    private static let key = "activityCategorySlots"

    static var assigned: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Kind for a task category, claiming a free slot the first time a category shows up.
    static func kind(for category: String?) -> ActivityKind {
        guard let name = category?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return .other }
        var slots = assigned
        if slots.contains(name) { return .category(name) }
        guard slots.count < count else { return .other }
        slots.append(name)
        UserDefaults.standard.set(slots, forKey: key)
        return .category(name)
    }

    static func slot(of name: String) -> Int? { assigned.firstIndex(of: name) }
}

/// The report plus GitHub counts for "Đã làm được gì".
struct ActivitySnapshot: Sendable {
    var report: ActivityReport
    var commits = 0
    var reviews = 0
    var pullRequests = 0

    static let empty = ActivitySnapshot(report: .empty)
}

/// Gathers the inputs for a range — Lịch from EventKit, GitHub / Jira from `activity_events`,
/// tasks from SwiftData — and builds the report. Reports are cached briefly per range.
@MainActor
enum ActivityLoader {
    private static var cache: [String: (snapshot: ActivitySnapshot, at: Date)] = [:]
    private static let cacheLife: TimeInterval = 120

    static func load(days: [Date], in context: ModelContext, now: Date = Date(), force: Bool = false) async -> ActivitySnapshot {
        guard let first = days.first, let last = days.last,
              let end = DayClock.calendar.date(byAdding: .day, value: 1, to: last) else { return .empty }
        let key = "\(first.timeIntervalSince1970)-\(days.count)"
        if !force, let hit = cache[key], now.timeIntervalSince(hit.at) < cacheLife { return hit.snapshot }

        var inputs = CalendarService.shared.meetings(from: first, to: min(end, now))
        let activity = await SupabaseService.shared.fetchActivity(
            from: first.addingTimeInterval(-ActivityEngine.sessionLead), to: end
        )
        inputs += ActivityEngine.githubSessions(
            activity.filter { $0.source == ExternalSource.github.rawValue }.map { (at: $0.startedAt, title: $0.title) }
        )
        inputs += activity.filter { $0.source == ExternalSource.jira.rawValue }.compactMap { log in
            guard let ended = log.endedAt, ended > log.startedAt else { return nil }
            return ActivityInput(start: log.startedAt, end: ended, kind: .jira, title: log.title,
                                 precision: .measured, source: .jira)
        }
        inputs += ActivityEngine.taskInputs(tasks(from: first, to: end, in: context), now: now,
                                            kind: ActivityCategorySlots.kind(for:))

        let report = ActivityEngine.report(inputs.filter { $0.start < now }, days: days)
        let github = activity.filter { $0.source == ExternalSource.github.rawValue && $0.startedAt >= first }
        let snapshot = ActivitySnapshot(
            report: report,
            // "3 commit · app-ios" → 3
            commits: github.filter { $0.kind == "push" }
                .reduce(0) { $0 + (Int($1.title.split(separator: " ").first ?? "") ?? 1) },
            reviews: github.filter { $0.kind == "review" }.count,
            pullRequests: Set(github.filter { $0.kind == "pull_request" }.map(\.title)).count
        )
        cache[key] = (snapshot, now)
        return snapshot
    }

    static func invalidate() { cache.removeAll() }

    private static func tasks(from start: Date, to end: Date, in context: ModelContext) -> [TaskActivity] {
        let all = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        return all.compactMap { task in
            let finished = task.status == .done ? task.completedAt : nil
            let running = task.status == .doing ? task.startedAt : nil
            guard let anchor = finished ?? running, anchor >= start.addingTimeInterval(-ActivityEngine.maxTimedTask),
                  anchor < end else { return nil }
            return TaskActivity(
                title: task.title,
                category: task.category,
                startedAt: task.startedAt,
                completedAt: finished,
                plannedMinutes: task.durationMinutes,
                linkedSource: ExternalSource(linkURL: task.linkURL)
            )
        }
    }
}
