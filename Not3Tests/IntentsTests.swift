import XCTest
@testable import Not3

@MainActor
final class IntentsTests: XCTestCase {
    private let now = DayClock.at(hour: 10, minute: 0, on: DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!)

    private func task(_ title: String, hour: Int? = nil, status: TaskStatus = .todo) -> TaskItem {
        let t = TaskItem(title: title, category: nil, plannedAt: hour.map { DayClock.at(hour: $0, minute: 0, on: now) },
                         durationMinutes: nil, source: .manual)
        t.createdAt = now
        t.statusRaw = status.rawValue
        if status == .done { t.completedAt = now }
        return t
    }

    func testTodayStatusText() {
        XCTAssertEqual(TodayStatus.text([], now: now), "Hôm nay chưa có việc nào.")
        XCTAssertEqual(TodayStatus.text([task("A", status: .done), task("B", status: .done)], now: now),
                       "Đã xong cả 2 việc hôm nay.")
        let tasks = [task("Học Anki", hour: 14), task("Viết test", hour: 16), task("Xong rồi", status: .done)]
        XCTAssertEqual(TodayStatus.text(tasks, now: now), "Còn 2 việc. Tiếp theo: 14:00 Học Anki.")
        let doing = task("Review PR #42", status: .doing)
        XCTAssertEqual(TodayStatus.text(tasks + [doing], now: now), "Còn 3 việc. Đang làm: Review PR #42.")
    }

    func testNextSkipsBacklogAndDoing() {
        let someday = task("Đọc sách")
        someday.isSomeday = true
        let doing = task("Đang làm", status: .doing)
        XCTAssertEqual(TodayStatus.next([someday, doing, task("Học Anki", hour: 14)], now: now)?.title, "Học Anki")
    }

    func testTaskDetail() {
        let t = task("Học Anki", hour: 14)
        t.durationMinutes = 25
        t.category = "Học ngôn ngữ"
        XCTAssertEqual(TaskEntity.detail(for: t, now: now), "Hôm nay 14:00 · 25 phút · Học ngôn ngữ")
        t.isSomeday = true
        XCTAssertEqual(TaskEntity.detail(for: t, now: now), "Hộp chờ · 25 phút · Học ngôn ngữ")
    }

    func testSpotlightIdentifiersRoundTrip() {
        let id = UUID()
        XCTAssertEqual(SpotlightIndexer.deepLink(for: SpotlightIndexer.identifier(note: id)), DeepLink.note(id))
        XCTAssertEqual(SpotlightIndexer.deepLink(for: SpotlightIndexer.identifier(task: id)), DeepLink.task(id))
        XCTAssertNil(SpotlightIndexer.deepLink(for: "folder:\(id.uuidString)"))
        XCTAssertNil(SpotlightIndexer.deepLink(for: "note:not-a-uuid"))
    }
}
