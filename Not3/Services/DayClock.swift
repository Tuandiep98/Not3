import Foundation

/// Calendar helpers in Vietnamese locale (weeks start on Monday).
enum DayClock {
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "vi_VN")
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    static func startOfDay(_ date: Date = Date()) -> Date {
        calendar.startOfDay(for: date)
    }

    static func endOfDay(_ date: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: 1, to: startOfDay(date))!
    }

    static func at(hour: Int, minute: Int, on date: Date = Date()) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    static func noon(_ date: Date = Date()) -> Date {
        at(hour: 12, minute: 0, on: date)
    }

    /// Monday of the week containing `date`.
    static func startOfWeek(_ date: Date = Date()) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? startOfDay(date)
    }

    static func daysOfWeek(_ date: Date = Date()) -> [Date] {
        let start = startOfWeek(date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func weekNumber(_ date: Date = Date()) -> Int {
        Calendar(identifier: .iso8601).component(.weekOfYear, from: date)
    }

    /// "2026-11-01" — the `date` column format on the server.
    static func isoDay(_ date: Date) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    static let shortWeekdays = ["T2", "T3", "T4", "T5", "T6", "T7", "CN"]

    static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "vi_VN")))
            .capitalizedFirst
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "vi_VN")))
    }

    static func dayMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.defaultDigits).locale(Locale(identifier: "vi_VN")))
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
