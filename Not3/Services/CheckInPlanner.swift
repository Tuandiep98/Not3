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
    /// Start of a free stretch found in the calendar, not one of the user's own slots.
    var isGap = false
}

/// A busy stretch of the day: a Calendar event or another planned task.
struct BusyInterval: Hashable, Sendable {
    let start: Date
    let end: Date
    let title: String
}

/// Whether a time chip fits the day as it stands.
enum Availability: Hashable, Sendable {
    /// Free; `minutes` until the next busy stretch, nil when it is open for 2 hours or more.
    case free(minutes: Int?)
    /// Overlaps this event or task.
    case busy(String)
}

/// "Nếu lỡ giờ thì…": the backup picked at check-in. If–then plans hold up better with a plan
/// for the obstacle (README §3); "Xếp lại" offers this one first when the time slips.
enum CopingPlan: String, CaseIterable, Identifiable, Sendable {
    case shorter, nextGap, evening, tomorrow

    /// "Làm 10 phút": the short version, started right away.
    static let shortMinutes = 10

    var id: String { rawValue }

    var chipLabel: String {
        switch self {
        case .shorter: "Làm \(Self.shortMinutes) phút"
        case .nextGap: "Dời sang lúc trống"
        case .evening: "Làm buổi tối"
        case .tomorrow: "Để mai"
        }
    }

    var systemImage: String {
        switch self {
        case .shorter: "timer"
        case .nextGap: "calendar.badge.clock"
        case .evening: "moon"
        case .tomorrow: "arrow.turn.up.right"
        }
    }

    /// Day-neutral, so "Dời sang mai" can keep the sentence as it is.
    var clause: String {
        switch self {
        case .shorter: "Nếu lỡ giờ, mình sẽ làm bản rút gọn \(Self.shortMinutes) phút."
        case .nextGap: "Nếu lỡ giờ, mình sẽ dời sang khoảng trống kế tiếp."
        case .evening: "Nếu lỡ giờ, mình sẽ làm vào buổi tối."
        case .tomorrow: "Nếu lỡ giờ, mình sẽ chuyển sang hôm sau."
        }
    }
}

/// Pure check-in logic. Rule-based fallback for when AI suggestions are unavailable
/// (README §10: most-used chips + categories missing in the last 7 days).
enum CheckInPlanner {
    /// Time chips computed from now, past times removed.
    /// `slots` are minutes after midnight (the user's list from "Tuỳ chỉnh lựa chọn").
    static func timeOptions(now: Date = Date(), slots: [Int] = AppSettings.checkInTimeSlots) -> [TimeOption] {
        var options = slots.sorted().compactMap { slot -> TimeOption? in
            let hour = slot / 60, minute = slot % 60
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

    /// "Lúc 14:00, mình sẽ học 20 từ vựng Anki trong 25 phút." + the coping clause when picked.
    static func sentence(task: String, time: TimeOption?, duration: Int?, coping: CopingPlan? = nil) -> String {
        let when: String
        if let time {
            when = time.id == "evening" ? "Tối nay" : "Lúc \(time.label)"
        } else {
            when = "Chiều nay"
        }
        return compose(when: when, task: task, duration: duration, coping: coping)
    }

    /// Same sentence for a task moved to `date` ("Lúc 15:10", "Mai lúc 14:00", "5/11 lúc 9:00").
    static func sentence(task: String, at date: Date?, duration: Int?, coping: CopingPlan?, now: Date = Date()) -> String {
        let cal = DayClock.calendar
        let when: String
        if let date {
            if cal.isDate(date, inSameDayAs: now) {
                when = "Lúc \(DayClock.time(date))"
            } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
                when = "Mai lúc \(DayClock.time(date))"
            } else {
                when = "\(DayClock.dayMonth(date)) lúc \(DayClock.time(date))"
            }
        } else {
            when = "Chiều nay"
        }
        return compose(when: when, task: task, duration: duration, coping: coping)
    }

    private static func compose(when: String, task: String, duration: Int?, coping: CopingPlan?) -> String {
        let action = task.prefix(1).lowercased() + task.dropFirst()
        var sentence = duration.map { "\(when), mình sẽ \(action) trong \($0) phút." } ?? "\(when), mình sẽ \(action)."
        if let coping { sentence += " " + coping.clause }
        return sentence
    }

    // MARK: Free time (Calendar + planned tasks)

    /// Plans are not offered past this hour ("Tối nay" is 20:00).
    static func dayEnd(_ now: Date) -> Date { DayClock.at(hour: 22, minute: 0, on: now) }

    /// A free stretch of 2 hours or more reads simply as "trống".
    static let openEnded = 120

    static func availability(at start: Date, duration: Int, busy: [BusyInterval], dayEnd: Date) -> Availability {
        let end = start.addingTimeInterval(Double(duration) * 60)
        if let clash = busy.filter({ $0.start < end && $0.end > start }).min(by: { $0.start < $1.start }) {
            return .busy(clash.title)
        }
        let next = busy.map(\.start).filter { $0 >= end }.min() ?? max(dayEnd, end)
        let minutes = Int(next.timeIntervalSince(start) / 60)
        return .free(minutes: minutes >= openEnded ? nil : minutes)
    }

    /// Free stretches long enough for `duration`, from a little after `now` until `dayEnd`.
    /// Starts are rounded up to 5 minutes.
    static func freeGaps(now: Date, duration: Int, busy: [BusyInterval], dayEnd: Date) -> [DateInterval] {
        let length = Double(duration) * 60
        var cursor = roundedUp(now.addingTimeInterval(5 * 60))
        var gaps: [DateInterval] = []
        for interval in busy.sorted(by: { $0.start < $1.start }) {
            if interval.end <= cursor { continue }
            if interval.start.timeIntervalSince(cursor) >= length {
                gaps.append(DateInterval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, roundedUp(interval.end))
        }
        if dayEnd.timeIntervalSince(cursor) >= length {
            gaps.append(DateInterval(start: cursor, end: dayEnd))
        }
        return gaps
    }

    /// Start of the next free stretch today, nil when the day is full.
    static func nextGap(now: Date, duration: Int, busy: [BusyInterval]) -> Date? {
        freeGaps(now: now, duration: duration, busy: busy, dayEnd: dayEnd(now)).first?.start
    }

    /// Extra chips for free stretches the user's own slots miss (up to `limit`), so a plan does not
    /// land on a meeting. A gap starting within 15 minutes of a free slot adds nothing.
    static func gapOptions(now: Date, duration: Int, busy: [BusyInterval], existing: [TimeOption], limit: Int = 2) -> [TimeOption] {
        let end = dayEnd(now)
        let freeSlots = existing.filter {
            if case .free = availability(at: $0.date, duration: duration, busy: busy, dayEnd: end) { return true }
            return false
        }
        var result: [TimeOption] = []
        for gap in freeGaps(now: now, duration: duration, busy: busy, dayEnd: end) {
            guard result.count < limit else { break }
            // A slot inside the gap already covers it.
            if freeSlots.contains(where: { $0.date >= gap.start.addingTimeInterval(-15 * 60) && $0.date < gap.end }) { continue }
            let label = DayClock.time(gap.start)
            result.append(TimeOption(id: "gap-\(label)", label: label, date: gap.start, isGap: true))
        }
        return result
    }

    /// The first chip that fits, else the first one.
    static func preferredTime(_ options: [TimeOption], duration: Int, busy: [BusyInterval], now: Date = Date()) -> TimeOption? {
        let end = dayEnd(now)
        return options.first { option in
            if case .free = availability(at: option.date, duration: duration, busy: busy, dayEnd: end) { return true }
            return false
        } ?? options.first
    }

    private static func roundedUp(_ date: Date) -> Date {
        let step = 5.0 * 60
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
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
            let lWork = lhs.isWork
            let rWork = rhs.isWork
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
    /// (built-ins and chips added in Cài đặt but never used yet stay, so the row is never empty).
    static func rankedCategories(_ chips: [Chip], now: Date = Date()) -> [Chip] {
        let cal = DayClock.calendar
        let twoWeeksAgo = cal.date(byAdding: .day, value: -14, to: now) ?? now
        let monthAgo = cal.date(byAdding: .day, value: -30, to: now) ?? now
        return chips
            .filter { $0.group == .category }
            .filter { chip in
                guard let last = chip.lastUsedAt else { return true }
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
