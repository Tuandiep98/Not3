import SwiftData
import XCTest
@testable import Not3

@MainActor
final class TodayListTests: XCTestCase {
    private let today = DayClock.at(hour: 10, minute: 0, on: DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!)

    private func task(_ title: String, created daysAgo: Int, planned: Int? = nil, status: TaskStatus = .todo, completedDaysAgo: Int? = nil) -> TaskItem {
        let cal = DayClock.calendar
        let t = TaskItem(title: title, category: nil,
                         plannedAt: planned.map { cal.date(byAdding: .day, value: -$0, to: today)! },
                         durationMinutes: nil, source: .integration)
        t.createdAt = cal.date(byAdding: .day, value: -daysAgo, to: today)!
        t.statusRaw = status.rawValue
        t.completedAt = completedDaysAgo.map { cal.date(byAdding: .day, value: -$0, to: today)! }
        return t
    }

    func testUnfinishedWorkCarriesOverWithoutAgeLimit() {
        let old = task("Review PR #42", created: 30)
        let overdue = task("Học Anki", created: 3, planned: 2)
        let doing = task("JIRA-120", created: 12, status: .doing)
        let shown = TodayList.tasks([old, overdue, doing], now: today).map(\.title)
        XCTAssertEqual(Set(shown), ["Review PR #42", "Học Anki", "JIRA-120"])
        XCTAssertTrue(TodayList.isCarriedOver(old, now: today))
    }

    func testFinishedOrEndedWorkStopsCarryingOver() {
        let doneToday = task("Done hôm nay", created: 5, status: .done, completedDaysAgo: 0)
        let doneYesterday = task("Done hôm qua", created: 5, status: .done, completedDaysAgo: 1)
        let cancelled = task("PR đóng không merge", created: 2, status: .cancelled)
        let shown = TodayList.tasks([doneToday, doneYesterday, cancelled], now: today).map(\.title)
        XCTAssertEqual(shown, ["Done hôm nay"], "done today stays (ticked); earlier done and cancelled are gone")
    }

    func testFuturePlansWaitForTheirDay() {
        let tomorrow = task("Mai làm", created: 0, planned: -1)
        XCTAssertTrue(TodayList.tasks([tomorrow], now: today).isEmpty)
    }

    func testOrderIsStableWhenTicking() {
        let a = task("A", created: 2)
        let b = task("B", created: 1)
        let before = TodayList.tasks([b, a], now: today).map(\.title)
        a.statusRaw = TaskStatus.done.rawValue
        a.completedAt = today
        let after = TodayList.tasks([b, a], now: today).map(\.title)
        XCTAssertEqual(before, ["A", "B"])
        XCTAssertEqual(after, ["A", "B"], "ticked task keeps its place")
    }
}
