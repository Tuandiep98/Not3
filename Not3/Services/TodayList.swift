import Foundation

/// Which tasks "Hôm nay" shows. Unfinished work carries over day after day — no age limit —
/// until it is ticked, or GitHub / Jira report it finished (done) or ended (cancelled).
enum TodayList {
    static func tasks(_ all: [TaskItem], now: Date = Date()) -> [TaskItem] {
        let start = DayClock.startOfDay(now)
        let end = DayClock.endOfDay(now)
        return all.filter { task in
            switch task.status {
            case .cancelled:
                return false
            case .done:
                // Finished today: stays in place, ticked. Finished earlier: gone.
                guard let completed = task.completedAt else { return false }
                return completed >= start && completed < end
            case .todo, .doing:
                // Everything open, except plans for a later day and the "Hộp chờ".
                if task.isSomeday { return false }
                if let planned = task.plannedAt { return planned < end }
                return true
            }
        }
        // Stable order (planned time, else creation): ticking never moves a row;
        // carried-over work naturally sits on top — except work that keeps slipping, which sinks
        // to the bottom until the user says "Vẫn làm" (`isStale`).
        .sorted { lhs, rhs in
            let lStale = isStale(lhs, now: now), rStale = isStale(rhs, now: now)
            if lStale != rStale { return rStale }
            return (lhs.plannedAt ?? lhs.createdAt, lhs.createdAt) < (rhs.plannedAt ?? rhs.createdAt, rhs.createdAt)
        }
    }

    /// Moved this many times, or carried over this many days, before "Vẫn muốn làm?" is asked.
    static let staleAfter = 3
    /// A plan counts as missed this long after its time without "Bắt đầu".
    static let missedGrace: TimeInterval = 10 * 60

    /// Planned for today, not started, and its time has passed: "Xếp lại" is offered.
    static func isMissed(_ task: TaskItem, now: Date = Date()) -> Bool {
        guard task.status == .todo, !task.isSomeday, let planned = task.plannedAt else { return false }
        return DayClock.calendar.isDate(planned, inSameDayAs: now) && now >= planned.addingTimeInterval(missedGrace)
    }

    /// Work the user keeps moving on: asked once "Vẫn muốn làm?" (Vẫn làm / Hộp chờ / Bỏ).
    /// GitHub / Jira work follows its source, repeating tasks replace themselves, so neither is asked.
    static func isStale(_ task: TaskItem, now: Date = Date()) -> Bool {
        guard task.status == .todo, !task.isSomeday, task.source != .integration, task.linkURL == nil,
              task.seriesId == nil else { return false }
        if task.postponeCount >= staleAfter { return true }
        let since = max(task.keptAt ?? .distantPast, task.plannedAt ?? task.createdAt)
        return daysCarried(since: since, now: now) >= staleAfter
    }

    /// Sorted by the user at "Khép lại hôm nay". GitHub / Jira work follows its source and
    /// repeating tasks replace themselves, so those are left alone.
    static func needsShutdownDecision(_ task: TaskItem) -> Bool {
        task.source != .integration && task.linkURL == nil && task.seriesId == nil
    }

    /// Whole days from `since` to today.
    static func daysCarried(since: Date, now: Date = Date()) -> Int {
        let cal = DayClock.calendar
        return cal.dateComponents([.day], from: DayClock.startOfDay(since), to: DayClock.startOfDay(now)).day ?? 0
    }

    /// "Hộp chờ": open work without a day, oldest first.
    static func backlog(_ all: [TaskItem]) -> [TaskItem] {
        all.filter { $0.isSomeday && ($0.status == .todo || $0.status == .doing) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Open work from before today (shown with its date).
    static func isCarriedOver(_ task: TaskItem, now: Date = Date()) -> Bool {
        guard !task.isSomeday, task.status == .todo || task.status == .doing else { return false }
        return (task.plannedAt ?? task.createdAt) < DayClock.startOfDay(now)
    }
}
