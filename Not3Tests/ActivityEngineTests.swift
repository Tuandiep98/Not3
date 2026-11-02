import XCTest
@testable import Not3

final class ActivityEngineTests: XCTestCase {
    private let day = DayClock.startOfDay(DayClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: 29))!)

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        DayClock.calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day)!
    }

    private func input(_ start: Date, _ end: Date, _ kind: ActivityKind, _ precision: ActivityPrecision,
                       _ source: ActivitySource = .task, title: String = "x") -> ActivityInput {
        ActivityInput(start: start, end: end, kind: kind, title: title, precision: precision, source: source)
    }

    func testGithubEventsBecomeSessionsWithLeadTime() {
        let sessions = ActivityEngine.githubSessions([
            (at: at(13, 25), title: "PR #57"), (at: at(14, 0), title: "PR #57"),
            (at: at(14, 40), title: "3 commit"), (at: at(16, 0), title: "Review #55"),
        ])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].start, at(13, 10))   // 15 min before the first event
        XCTAssertEqual(sessions[0].end, at(14, 40))
        XCTAssertEqual(sessions[0].title, "PR #57")     // most frequent title
        XCTAssertEqual(sessions[1].start, at(15, 45))   // lone event = 15 min
        XCTAssertEqual(sessions[1].precision, .estimated)
    }

    func testOverlapsCountOnceAndMeasuredWins() {
        let report = ActivityEngine.report([
            input(at(9), at(10), .meeting, .measured, .calendar, title: "Sprint planning"),
            input(at(9, 30), at(10, 30), .code, .estimated, .github, title: "PR #57"),
        ], days: [day])
        XCTAssertEqual(report.total, 90)                 // not 120
        XCTAssertEqual(report.perDay[0][.meeting], 60)
        XCTAssertEqual(report.perDay[0][.code], 30)
        XCTAssertEqual(report.overlapsResolved, 1)
        XCTAssertEqual(report.blocks.map(\.start), [at(9), at(10)])
    }

    func testBlocksSplitAcrossHoursInTheHeatMap() {
        let report = ActivityEngine.report([input(at(13, 40), at(15, 10), .code, .measured)], days: [day])
        XCTAssertEqual(report.heat[0][13], 20)
        XCTAssertEqual(report.heat[0][14], 60)
        XCTAssertEqual(report.heat[0][15], 10)
    }

    func testDeepFocusNeedsFiftyMinutesWithoutMeetings() {
        let report = ActivityEngine.report([
            input(at(13), at(13, 30), .code, .measured),
            input(at(13, 33), at(14, 0), .jira, .measured),     // 3 min gap → joined: 60 min
            input(at(14, 0), at(14, 30), .meeting, .measured, .calendar),
            input(at(14, 30), at(15, 0), .code, .measured),     // after a meeting: 30 min only
        ], days: [day])
        XCTAssertEqual(report.deepFocus.count, 1)
        XCTAssertEqual(report.deepFocusMinutes, 60)
    }

    func testTimedTasksAreMeasuredAndUntimedUsePlannedDuration() {
        let inputs = ActivityEngine.taskInputs([
            TaskActivity(title: "Học Anki", category: "Học", startedAt: at(19, 40), completedAt: at(20, 20),
                         plannedMinutes: 25, linkedSource: nil),
            TaskActivity(title: "Đi bộ", category: "Sức khoẻ", startedAt: nil, completedAt: at(18),
                         plannedMinutes: 30, linkedSource: nil),
            TaskActivity(title: "Review PR #42", category: "Công việc", startedAt: nil, completedAt: at(11),
                         plannedMinutes: 30, linkedSource: .github),
        ], now: at(23)) { .category($0 ?? "") }
        XCTAssertEqual(inputs.count, 2)                  // linked + untimed: its PR time counts instead
        XCTAssertEqual(inputs[0].precision, .measured)
        XCTAssertEqual(inputs[0].end.timeIntervalSince(inputs[0].start), 40 * 60)
        XCTAssertEqual(inputs[1].precision, .planned)
        XCTAssertEqual(inputs[1].start, at(17, 30))
    }

    func testInputsAreClippedToTheRange() {
        let report = ActivityEngine.report([input(at(23, 30), at(24, 30), .code, .measured)], days: [day])
        XCTAssertEqual(report.total, 30)
    }
}
