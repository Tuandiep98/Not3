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
                // Everything open, except plans for a later day.
                if let planned = task.plannedAt { return planned < end }
                return true
            }
        }
        // Stable order (planned time, else creation): ticking never moves a row;
        // carried-over work naturally sits on top.
        .sorted { ($0.plannedAt ?? $0.createdAt, $0.createdAt) < ($1.plannedAt ?? $1.createdAt, $1.createdAt) }
    }

    /// Open work from before today (shown with its date).
    static func isCarriedOver(_ task: TaskItem, now: Date = Date()) -> Bool {
        guard task.status == .todo || task.status == .doing else { return false }
        return (task.plannedAt ?? task.createdAt) < DayClock.startOfDay(now)
    }
}
