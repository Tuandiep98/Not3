import HealthKit
import SwiftData
import XCTest
@testable import Not3

@MainActor
final class AppleModulesTests: XCTestCase {
    private let day = DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        DayClock.at(hour: hour, minute: minute, on: day)
    }

    // MARK: Focus Filter

    func testFocusFilterKeepsChosenCategories() {
        let work = TaskItem(title: "Review PR", category: "Công việc", plannedAt: nil, durationMinutes: nil, source: .manual)
        let study = TaskItem(title: "Anki", category: "Học ngôn ngữ", plannedAt: nil, durationMinutes: nil, source: .manual)
        let loose = TaskItem(title: "Gọi điện", category: nil, plannedAt: nil, durationMinutes: nil, source: .manual)
        let all = [work, study, loose]

        XCTAssertEqual(FocusFilterState.apply(all, categories: [], showUncategorized: false).count, 3, "No categories = no filter")
        XCTAssertEqual(FocusFilterState.apply(all, categories: ["Công việc"], showUncategorized: true).map(\.title), ["Review PR", "Gọi điện"])
        XCTAssertEqual(FocusFilterState.apply(all, categories: ["Công việc"], showUncategorized: false).map(\.title), ["Review PR"])
    }

    func testFocusCategoriesRoundTripThroughOneString() {
        XCTAssertEqual(FocusFilterState.decode("Công việc\nHọc ngôn ngữ"), ["Công việc", "Học ngôn ngữ"])
        XCTAssertEqual(FocusFilterState.decode(""), [])
    }

    // MARK: Sức khỏe

    func testOverlappingSleepFromPhoneAndWatchCountsOnce() {
        let merged = HealthService.union([
            (at(0), at(6)),        // iPhone
            (at(0, 30), at(6, 45)), // Watch
            (at(13), at(13, 20)),  // nap
            (at(14), at(13)),      // broken sample
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].0, at(0))
        XCTAssertEqual(merged[0].1, at(6, 45))
        XCTAssertEqual(merged[1].1, at(13, 20))
    }

    func testHoursText() {
        XCTAssertEqual(HealthService.hoursText(435), "7 giờ 15 phút")
        XCTAssertEqual(HealthService.hoursText(420), "7 giờ")
        XCTAssertEqual(HealthService.hoursText(40), "40 phút")
    }

    func testWorkoutNames() {
        XCTAssertEqual(HealthService.activityName(.running), "Chạy bộ")
        XCTAssertEqual(HealthService.activityName(.functionalStrengthTraining), "Tập sức mạnh")
        XCTAssertEqual(HealthService.activityName(.curling), "Tập luyện")
    }

    // MARK: Nhật ký

    func testAppleSourcesGoIntoTheJournal() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let reminder = ExternalItem(source: .reminders, externalId: "r1", title: "Mua sữa", url: nil, occurredAt: at(8))
        let run = ExternalItem(source: .health, externalId: "w1", title: "Chạy bộ 32 phút · 5,1 km", url: nil, occurredAt: at(6, 30))
        let moment = ExternalItem(source: .journal, externalId: "m1", title: "Highlands Coffee", url: nil, occurredAt: at(15))
        [reminder, run, moment].forEach(context.insert)

        let entries = JournalService.collect(in: context, now: at(20))
        XCTAssertEqual(entries.map(\.line), [
            "• Sức khỏe · Chạy bộ 32 phút · 5,1 km",
            "✓ Mua sữa",
            "• Gợi ý nhật ký · Highlands Coffee",
        ])
        XCTAssertEqual(JournalService.summary(entries), "1 việc xong · 1 hoạt động Sức khỏe · 1 Gợi ý nhật ký")
        _ = container
    }

    func testServerPullLeavesDeviceSourcesAlone() {
        XCTAssertEqual(ExternalSource.server, [.github, .jira])
        for source in LocalModule.all {
            XCTAssertFalse(ExternalSource.server.contains(source))
        }
    }

    // MARK: Lời nhắc / Sức khỏe options

    func testModuleOptionsFallBackToDefaults() {
        let key = "module.health.options"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(LocalModule.isOn("workouts", for: .health))

        LocalModule.setOptions(.health, ["workouts": false])
        XCTAssertFalse(LocalModule.isOn("workouts", for: .health))
        XCTAssertTrue(LocalModule.isOn("sleep", for: .health))
        XCTAssertFalse(LocalModule.isOn("unknown", for: .health))
    }
}
