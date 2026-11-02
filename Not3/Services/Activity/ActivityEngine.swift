import Foundation

// "Tổng kết tuần" v2: turns every source into time blocks, removes overlaps, then buckets them
// per day, hour and kind. Pure value code (unit-tested); ActivityLoader gathers the inputs.
//
//   Lịch        → start–end of each meeting                 measured
//   Jira        → my work logs: started + time spent          measured
//   Việc Not3   → Bắt đầu → Xong                              measured
//                 no timer: the planned duration, ending at Xong   planned
//   GitHub      → my events grouped into sessions             estimated
// Overlaps count once: measured beats planned beats estimated.

enum ActivityKind: Hashable, Sendable {
    case code
    case meeting
    case jira
    /// One of the task categories that has its own colour (see ActivityCategorySlots).
    case category(String)
    case other
}

enum ActivityPrecision: Int, Comparable, Sendable {
    case measured = 0, planned = 1, estimated = 2
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum ActivitySource: String, Sendable {
    case calendar, jira, task, github
}

struct ActivityInput: Sendable, Equatable {
    var start: Date
    var end: Date
    var kind: ActivityKind
    var title: String
    var precision: ActivityPrecision
    var source: ActivitySource
}

struct ActivityBlock: Identifiable, Sendable, Equatable {
    var id: String { "\(source.rawValue)|\(start.timeIntervalSince1970)|\(title)" }
    var start: Date
    var end: Date
    var kind: ActivityKind
    var title: String
    var precision: ActivityPrecision
    var source: ActivitySource
    var minutes: Int { max(0, Int((end.timeIntervalSince(start) / 60).rounded())) }
}

/// A finished (or running) task, as the engine needs it.
struct TaskActivity: Sendable {
    var title: String
    var category: String?
    var startedAt: Date?
    var completedAt: Date?
    var plannedMinutes: Int?
    /// Linked PR / ticket: its time already shows up through GitHub / Jira.
    var linkedSource: ExternalSource?
}

struct ActivityReport: Sendable {
    var days: [Date]
    var blocks: [ActivityBlock]
    /// minutes[day][kind]
    var perDay: [[ActivityKind: Int]]
    /// minutes[day][hour 0–23]
    var heat: [[Int]]
    var deepFocus: [DateInterval]
    /// Pieces dropped because a more precise source already covered that time.
    var overlapsResolved: Int

    var total: Int { perDay.reduce(0) { $0 + $1.values.reduce(0, +) } }
    func total(day: Int) -> Int { perDay[day].values.reduce(0, +) }
    var byKind: [ActivityKind: Int] {
        perDay.reduce(into: [:]) { acc, day in day.forEach { acc[$0.key, default: 0] += $0.value } }
    }
    var deepFocusMinutes: Int { deepFocus.reduce(0) { $0 + Int($1.duration / 60) } }

    static let empty = ActivityReport(days: [], blocks: [], perDay: [], heat: [], deepFocus: [], overlapsResolved: 0)
}

enum ActivityEngine {
    /// GitHub events closer than this belong to one session.
    static let sessionGap: TimeInterval = 45 * 60
    /// Reading / thinking before the first event of a session; also the length of a lone event.
    static let sessionLead: TimeInterval = 15 * 60
    static let deepFocusMinimum: TimeInterval = 50 * 60
    /// Blocks this close count as one stretch for deep focus.
    static let joinGap: TimeInterval = 5 * 60
    /// A timer left running longer than this is not trusted.
    static let maxTimedTask: TimeInterval = 10 * 3600

    // MARK: Inputs

    /// GitHub events → estimated sessions: events ≤ 45 min apart join; each session starts 15 min
    /// before its first event.
    static func githubSessions(_ events: [(at: Date, title: String)]) -> [ActivityInput] {
        let sorted = events.sorted { $0.at < $1.at }
        var sessions: [ActivityInput] = []
        var titles: [String: Int] = [:]
        for event in sorted {
            if var last = sessions.last, event.at.timeIntervalSince(last.end) <= sessionGap {
                last.end = max(last.end, event.at)
                titles[event.title, default: 0] += 1
                last.title = titles.max { $0.value < $1.value }?.key ?? last.title
                sessions[sessions.count - 1] = last
            } else {
                titles = [event.title: 1]
                sessions.append(ActivityInput(start: event.at.addingTimeInterval(-sessionLead), end: event.at,
                                              kind: .code, title: event.title, precision: .estimated, source: .github))
            }
        }
        return sessions
    }

    static func taskInputs(_ tasks: [TaskActivity], now: Date, kind: (String?) -> ActivityKind) -> [ActivityInput] {
        tasks.compactMap { task in
            let taskKind: ActivityKind = switch task.linkedSource {
            case .github: .code
            case .jira: .jira
            default: kind(task.category)
            }
            if let started = task.startedAt {
                let end = task.completedAt ?? now
                let span = end.timeIntervalSince(started)
                if span >= 60, span <= maxTimedTask {
                    return ActivityInput(start: started, end: end, kind: taskKind, title: task.title,
                                         precision: .measured, source: .task)
                }
            }
            // No timer: the planned duration, ending when it was ticked. Linked tasks are skipped
            // (their PR / ticket time already counts).
            guard task.linkedSource == nil, let done = task.completedAt,
                  let planned = task.plannedMinutes, planned > 0 else { return nil }
            return ActivityInput(start: done.addingTimeInterval(-Double(planned) * 60), end: done, kind: taskKind,
                                 title: task.title, precision: .planned, source: .task)
        }
    }

    // MARK: Overlaps

    /// Places inputs from most to least precise; each keeps only the time nobody covered yet.
    static func merge(_ inputs: [ActivityInput]) -> (blocks: [ActivityBlock], overlapsResolved: Int) {
        let ordered = inputs.filter { $0.end > $0.start }
            .sorted { ($0.precision, $0.start) < ($1.precision, $1.start) }
        var placed: [ActivityBlock] = []
        var resolved = 0
        for input in ordered {
            var pieces = [(input.start, input.end)]
            for block in placed where block.end > input.start && block.start < input.end {
                pieces = pieces.flatMap { piece -> [(Date, Date)] in
                    guard block.end > piece.0, block.start < piece.1 else { return [piece] }
                    var out: [(Date, Date)] = []
                    if block.start > piece.0 { out.append((piece.0, block.start)) }
                    if block.end < piece.1 { out.append((block.end, piece.1)) }
                    return out
                }
            }
            let kept = pieces.filter { $0.1.timeIntervalSince($0.0) >= 60 }
            if kept.count != 1 || kept.first.map({ $0.0 != input.start || $0.1 != input.end }) == true { resolved += 1 }
            placed += kept.map {
                ActivityBlock(start: $0.0, end: $0.1, kind: input.kind, title: input.title,
                              precision: input.precision, source: input.source)
            }
        }
        return (placed.sorted { $0.start < $1.start }, resolved)
    }

    // MARK: Report

    static func report(_ inputs: [ActivityInput], days: [Date], calendar: Calendar = DayClock.calendar) -> ActivityReport {
        guard let first = days.first, let last = days.last,
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: last) else { return .empty }
        let clipped = inputs.compactMap { input -> ActivityInput? in
            var copy = input
            copy.start = max(input.start, first)
            copy.end = min(input.end, rangeEnd)
            return copy.end > copy.start ? copy : nil
        }
        let (blocks, resolved) = merge(clipped)
        var perDay = Array(repeating: [ActivityKind: Int](), count: days.count)
        var heatSeconds = Array(repeating: Array(repeating: 0.0, count: 24), count: days.count)
        var kindSeconds = Array(repeating: [ActivityKind: Double](), count: days.count)

        for block in blocks {
            var cursor = block.start
            while cursor < block.end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor) else { break }
                let pieceEnd = min(block.end, hour.end)
                let seconds = pieceEnd.timeIntervalSince(cursor)
                if let day = days.lastIndex(where: { $0 <= cursor }) {
                    let h = calendar.component(.hour, from: cursor)
                    heatSeconds[day][h] += seconds
                    kindSeconds[day][block.kind, default: 0] += seconds
                }
                cursor = pieceEnd
            }
        }
        for day in days.indices {
            perDay[day] = kindSeconds[day].mapValues { Int(($0 / 60).rounded()) }.filter { $0.value > 0 }
        }
        let heat = heatSeconds.map { $0.map { min(60, Int(($0 / 60).rounded())) } }
        return ActivityReport(days: days, blocks: blocks, perDay: perDay, heat: heat,
                              deepFocus: deepFocus(blocks), overlapsResolved: resolved)
    }

    /// Stretches of work (meetings excluded) of 50 min or more; blocks ≤ 5 min apart join.
    static func deepFocus(_ blocks: [ActivityBlock]) -> [DateInterval] {
        let work = blocks.filter { $0.kind != .meeting }.sorted { $0.start < $1.start }
        var stretches: [DateInterval] = []
        var current: DateInterval?
        for block in work {
            if let open = current, block.start.timeIntervalSince(open.end) <= joinGap,
               DayClock.calendar.isDate(block.start, inSameDayAs: open.start) {
                current = DateInterval(start: open.start, end: max(open.end, block.end))
            } else {
                if let open = current, open.duration >= deepFocusMinimum { stretches.append(open) }
                current = DateInterval(start: block.start, end: block.end)
            }
        }
        if let open = current, open.duration >= deepFocusMinimum { stretches.append(open) }
        return stretches
    }
}
