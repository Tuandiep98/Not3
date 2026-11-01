import XCTest
@testable import Not3

final class VoiceChipParserTests: XCTestCase {
    func testFullSentence() {
        let result = VoiceChipParser.parse("Chiều nay lúc 3 giờ rưỡi học tiếng Anh 25 phút")
        XCTAssertEqual(result, VoiceParse(title: "Học tiếng Anh", durationMinutes: 25, hour: 15, minute: 30))
    }

    func testHourMinuteFormat() {
        let result = VoiceChipParser.parse("15h45 viết test module login trong 45 phút")
        XCTAssertEqual(result, VoiceParse(title: "Viết test module login", durationMinutes: 45, hour: 15, minute: 45))
    }

    func testHoursDuration() {
        let result = VoiceChipParser.parse("tối nay đọc sách 1 tiếng")
        XCTAssertEqual(result.title, "Đọc sách")
        XCTAssertEqual(result.durationMinutes, 60)
        XCTAssertNil(result.hour)
    }

    func testNumberInsideTitleIsNotATime() {
        let result = VoiceChipParser.parse("học 20 từ vựng Anki")
        XCTAssertEqual(result.title, "Học 20 từ vựng Anki")
        XCTAssertNil(result.hour)
        XCTAssertNil(result.durationMinutes)
    }

    func testEveningHourShift() {
        let result = VoiceChipParser.parse("lúc 9 giờ tối đi bộ nửa tiếng")
        XCTAssertEqual(result.hour, 21)
        XCTAssertEqual(result.durationMinutes, 30)
        XCTAssertEqual(result.title, "Đi bộ")
    }
}

final class TaskActionsTests: XCTestCase {
    func testTomorrowSentence() {
        XCTAssertEqual(TaskActions.tomorrowSentence("Lúc 14:00, mình sẽ đi bộ."), "Mai lúc 14:00, mình sẽ đi bộ.")
        XCTAssertEqual(TaskActions.tomorrowSentence("Tối nay, mình sẽ đọc sách."), "Tối mai, mình sẽ đọc sách.")
        XCTAssertEqual(TaskActions.tomorrowSentence("Mai lúc 9:00, x."), "Mai lúc 9:00, x.")
    }

    @MainActor
    func testEveningTimeIsNineOrAfterTaskEnds() {
        let day = DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let early = TaskItem(title: "a", category: nil, plannedAt: DayClock.at(hour: 14, minute: 0, on: day), durationMinutes: 25, source: .manual)
        XCTAssertEqual(NotificationService.eveningTime(for: early), DayClock.at(hour: 21, minute: 0, on: day))
        let late = TaskItem(title: "b", category: nil, plannedAt: DayClock.at(hour: 20, minute: 30, on: day), durationMinutes: 45, source: .manual)
        XCTAssertEqual(NotificationService.eveningTime(for: late), DayClock.at(hour: 21, minute: 30, on: day))
    }
}
