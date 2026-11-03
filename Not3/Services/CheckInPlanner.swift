import Foundation
import SwiftData

/// A chip offered in "Chiều nay làm gì?".
struct AfternoonSuggestion: Identifiable, Hashable, Sendable {
    var id: String { "\(category ?? "")|\(title)" }
    let title: String
    let category: String?
    let source: TaskSource
    var durationMinutes: Int? = nil
    /// Row id in `suggestions` when the chip came from the server (marked picked/dismissed on save).
    var serverId: UUID? = nil
    /// An existing unfinished task: choosing it reschedules that task instead of creating a copy.
    var taskId: UUID? = nil
    /// "source|externalId" of a synced item (GitHub / Jira): the new task gets linked to it.
    var externalKey: String? = nil
}

/// A time chip ("14:00", "Tối nay").
struct TimeOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let date: Date
}

/// Pure check-in logic. Rule-based fallback for when AI suggestions are unavailable
/// (README §10: most-used chips + categories missing in the last 7 days).
enum CheckInPlanner {
    /// Time chips computed from now, past times removed.
    static func timeOptions(now: Date = Date()) -> [TimeOption] {
        let slots: [(Int, Int)] = [(14, 0), (15, 30), (17, 0)]
        var options = slots.compactMap { hour, minute -> TimeOption? in
            let date = DayClock.at(hour: hour, minute: minute, on: now)
            guard date > now else { return nil }
            let label = String(format: "%02d:%02d", hour, minute)
            return TimeOption(id: label, label: label, date: date)
        }
        let evening = DayClock.at(hour: 20, minute: 0, on: now)
        if evening > now {
            options.append(TimeOption(id: "evening", label: "Tối nay", date: evening))
        }
        return options
    }

    /// "Lúc 14:00, mình sẽ học 20 từ vựng Anki trong 25 phút."
    static func sentence(task: String, time: TimeOption?, duration: Int?) -> String {
        let when: String
        if let time {
            when = time.id == "evening" ? "Tối nay" : "Lúc \(time.label)"
        } else {
            when = "Chiều nay"
        }
        let action = task.prefix(1).lowercased() + task.dropFirst()
        if let duration {
            return "\(when), mình sẽ \(action) trong \(duration) phút."
        }
        return "\(when), mình sẽ \(action)."
    }

    /// Up to 3 afternoon suggestions.
    /// - Categories not used in the last 7 days come first, self-development before work.
    /// - Each category uses its most frequent recent task title, else the category name.
    static func suggestions(
        categories: [Chip],
        recentTasks: [TaskItem],
        now: Date = Date(),
        limit: Int = 3
    ) -> [AfternoonSuggestion] {
        let weekAgo = DayClock.calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let usedThisWeek = Set(
            recentTasks.filter { ($0.completedAt ?? $0.createdAt) >= weekAgo }.compactMap(\.category)
        )
        let ranked = rankedCategories(categories, now: now)
        let ordered = ranked.sorted { lhs, rhs in
            let lMissing = !usedThisWeek.contains(lhs.label)
            let rMissing = !usedThisWeek.contains(rhs.label)
            if lMissing != rMissing { return lMissing }
            let lWork = lhs.label == ChipCatalog.workCategory
            let rWork = rhs.label == ChipCatalog.workCategory
            if lWork != rWork { return !lWork }
            return false
        }
        return ordered.prefix(limit).map { chip in
            AfternoonSuggestion(
                title: frequentTitle(for: chip.label, in: recentTasks) ?? chip.label,
                category: chip.label,
                source: .manual
            )
        }
    }

    /// "Hộp chờ" items offered after the other suggestions; choosing one schedules that task.
    static func backlogSuggestions(_ tasks: [TaskItem], limit: Int = 3) -> [AfternoonSuggestion] {
        TodayList.backlog(tasks).prefix(limit).map { task in
            AfternoonSuggestion(title: task.title, category: task.category, source: task.source,
                                durationMinutes: task.durationMinutes, taskId: task.id)
        }
    }

    /// Chips used most in the last 14 days first; chips unused for 30 days are hidden
    /// (built-ins stay so the row is never empty).
    static func rankedCategories(_ chips: [Chip], now: Date = Date()) -> [Chip] {
        let cal = DayClock.calendar
        let twoWeeksAgo = cal.date(byAdding: .day, value: -14, to: now) ?? now
        let monthAgo = cal.date(byAdding: .day, value: -30, to: now) ?? now
        return chips
            .filter { $0.group == .category }
            .filter { chip in
                guard let last = chip.lastUsedAt else { return chip.isBuiltIn }
                return last >= monthAgo || chip.isBuiltIn
            }
            .sorted { lhs, rhs in
                let lRecent = (lhs.lastUsedAt ?? .distantPast) >= twoWeeksAgo ? lhs.useCount : 0
                let rRecent = (rhs.lastUsedAt ?? .distantPast) >= twoWeeksAgo ? rhs.useCount : 0
                if lRecent != rRecent { return lRecent > rRecent }
                return lhs.label.localizedCompare(rhs.label) == .orderedAscending
            }
    }

    private static func frequentTitle(for category: String, in tasks: [TaskItem]) -> String? {
        let titles = tasks.filter { $0.category == category && $0.title != category }.map(\.title)
        let counts = Dictionary(titles.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key
    }

    /// A day is "meaningful" when at least one task was finished that day.
    static func isMeaningful(day: Date, tasks: [TaskItem]) -> Bool {
        let start = DayClock.startOfDay(day)
        let end = DayClock.endOfDay(day)
        return tasks.contains { task in
            guard task.status == .done, let done = task.completedAt else { return false }
            return done >= start && done < end
        }
    }
}
