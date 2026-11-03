import SwiftData
import XCTest
@testable import Not3

@MainActor
final class RecurrenceTests: XCTestCase {
    /// Monday 2 Nov 2026, 08:00.
    private let monday = DayClock.at(hour: 8, minute: 0, on: DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!)

    private func day(_ offset: Int) -> Date {
        DayClock.calendar.date(byAdding: .day, value: offset, to: monday)!
    }

    func testRawValueRoundTrip() {
        for rule in [Recurrence.daily, .weekdays, .weekly([1, 3, 5]), .monthly(15)] {
            XCTAssertEqual(Recurrence(rawValue: rule.rawValue), rule)
        }
        XCTAssertEqual(Recurrence.weekly([5, 1, 3]).rawValue, "weekly:1,3,5")
        XCTAssertNil(Recurrence(rawValue: "weekly:"))
        XCTAssertNil(Recurrence(rawValue: "monthly:40"))
        XCTAssertNil(Recurrence(rawValue: "yearly"))
    }

    func testOccurs() {
        XCTAssertEqual(Recurrence.weekday(of: monday), 1)
        XCTAssertTrue(Recurrence.weekdays.occurs(on: day(4)), "Friday")
        XCTAssertFalse(Recurrence.weekdays.occurs(on: day(5)), "Saturday")
        XCTAssertTrue(Recurrence.weekly([3]).occurs(on: day(2)), "Wednesday")
        XCTAssertFalse(Recurrence.weekly([3]).occurs(on: day(1)))
        XCTAssertTrue(Recurrence.monthly(2).occurs(on: monday))
        // 31 falls on the last day of a 30-day month.
        let nov30 = DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 30))!
        XCTAssertTrue(Recurrence.monthly(31).occurs(on: nov30))
    }

    func testGeneratesOncePerDayAndCancelsTheOpenPreviousOne() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let series = TaskSeries(title: "Học Anki", category: "Học ngôn ngữ", rule: .daily, startDay: monday)
        series.hour = 9
        series.durationMinutes = 25
        context.insert(series)

        let first = RecurrenceService.generateOccurrences(in: context, now: monday)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.plannedAt, DayClock.at(hour: 9, minute: 0, on: monday))
        XCTAssertEqual(first.first?.seriesId, series.id)
        XCTAssertTrue(RecurrenceService.generateOccurrences(in: context, now: monday).isEmpty, "same day: no second copy")

        let second = RecurrenceService.generateOccurrences(in: context, now: day(1))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first.first?.status, .cancelled, "yesterday's open occurrence does not pile up")
    }

    func testFinishedOccurrenceIsKeptAndPausedSeriesStops() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let series = TaskSeries(title: "Chạy bộ", category: "Sức khoẻ", rule: .weekdays, startDay: monday)
        context.insert(series)
        let done = try XCTUnwrap(RecurrenceService.generateOccurrences(in: context, now: monday).first)
        done.status = .done

        RecurrenceService.generateOccurrences(in: context, now: day(1))
        XCTAssertEqual(done.status, .done)
        XCTAssertTrue(RecurrenceService.generateOccurrences(in: context, now: day(5)).isEmpty, "Saturday")

        RecurrenceService.stop(series)
        XCTAssertTrue(RecurrenceService.generateOccurrences(in: context, now: day(7)).isEmpty)
    }

    func testMakeRepeatingUsesTheTaskAsTodaysOccurrence() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let task = TaskItem(title: "Viết nhật ký", category: nil, plannedAt: DayClock.at(hour: 21, minute: 30, on: monday),
                            durationMinutes: 15, source: .manual)
        context.insert(task)
        let series = RecurrenceService.makeRepeating(task, rule: .daily, addToCalendar: false, in: context)
        XCTAssertEqual(series.hour, 21)
        XCTAssertEqual(series.minute, 30)
        XCTAssertEqual(task.seriesId, series.id)
        XCTAssertTrue(RecurrenceService.generateOccurrences(in: context, now: monday).isEmpty)
        XCTAssertEqual(RecurrenceService.generateOccurrences(in: context, now: day(1)).count, 1)
    }
}
