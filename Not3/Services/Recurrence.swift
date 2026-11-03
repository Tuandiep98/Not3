import Foundation

/// How a task repeats. Stored as a short string ("daily", "weekdays", "weekly:1,3,5", "monthly:15").
/// Weekdays use Monday = 1 … Sunday = 7.
enum Recurrence: Hashable, Sendable {
    case daily
    case weekdays
    case weekly(Set<Int>)
    case monthly(Int)

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "daily": self = .daily
        case "weekdays": self = .weekdays
        case "weekly":
            let days = Set((parts.last ?? "").split(separator: ",").compactMap { Int($0) }.filter { (1...7).contains($0) })
            guard parts.count == 2, !days.isEmpty else { return nil }
            self = .weekly(days)
        case "monthly":
            guard parts.count == 2, let day = Int(parts[1]), (1...31).contains(day) else { return nil }
            self = .monthly(day)
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .daily: "daily"
        case .weekdays: "weekdays"
        case .weekly(let days): "weekly:" + days.sorted().map(String.init).joined(separator: ",")
        case .monthly(let day): "monthly:\(day)"
        }
    }

    /// Monday = 1 … Sunday = 7.
    static func weekday(of date: Date) -> Int {
        let weekday = DayClock.calendar.component(.weekday, from: date)  // 1 = Sunday
        return (weekday + 5) % 7 + 1
    }

    func occurs(on date: Date) -> Bool {
        switch self {
        case .daily:
            return true
        case .weekdays:
            return Self.weekday(of: date) <= 5
        case .weekly(let days):
            return days.contains(Self.weekday(of: date))
        case .monthly(let day):
            // 31 in a 30-day month (or February) falls on the month's last day.
            let cal = DayClock.calendar
            let today = cal.component(.day, from: date)
            let lastDay = cal.range(of: .day, in: .month, for: date)?.count ?? 31
            return today == min(day, lastDay)
        }
    }

    var label: String {
        switch self {
        case .daily: return "Hằng ngày"
        case .weekdays: return "Ngày thường (T2–T6)"
        case .weekly(let days):
            if days.count == 1, let day = days.first { return "Hằng tuần · \(Self.dayLabel(day))" }
            return days.sorted().map(Self.dayLabel).joined(separator: ", ")
        case .monthly(let day): return "Ngày \(day) hằng tháng"
        }
    }

    static func dayLabel(_ day: Int) -> String {
        DayClock.shortWeekdays[(day - 1) % 7]
    }
}
