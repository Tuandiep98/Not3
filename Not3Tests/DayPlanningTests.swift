import SwiftData
import XCTest
@testable import Not3

/// Free time around meetings, "Nếu lỡ giờ thì…", "Xếp lại" and "Vẫn muốn làm?".
@MainActor
final class DayPlanningTests: XCTestCase {
    private func date(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let day = DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2 + dayOffset))!
        return DayClock.at(hour: hour, minute: minute, on: day)
    }

    private func busy(_ startHour: Int, _ startMinute: Int, _ endHour: Int, _ endMinute: Int, _ title: String = "Họp") -> BusyInterval {
        BusyInterval(start: date(startHour, startMinute), end: date(endHour, endMinute), title: title)
    }

    // MARK: Availability

    func testSlotOverlappingAMeetingIsBusy() {
        let meetings = [busy(14, 30, 15, 0, "Họp sprint")]
        let result = CheckInPlanner.availability(at: date(14), duration: 45, busy: meetings, dayEnd: date(22))
        XCTAssertEqual(result, .busy("Họp sprint"), "14:00 + 45′ runs into the 14:30 meeting")
    }

    func testSlotBeforeAMeetingShowsTheTimeLeft() {
        let meetings = [busy(14, 30, 15, 0)]
        let result = CheckInPlanner.availability(at: date(14), duration: 25, busy: meetings, dayEnd: date(22))
        XCTAssertEqual(result, .free(minutes: 30))
    }

    func testLongFreeStretchIsOpenEnded() {
        let result = CheckInPlanner.availability(at: date(15, 30), duration: 25, busy: [], dayEnd: date(22))
        XCTAssertEqual(result, .free(minutes: nil))
    }

    func testFreeGapsSkipMeetingsAndRoundUp() {
        let meetings = [busy(13, 0, 14, 2), busy(14, 30, 16, 0)]
        let gaps = CheckInPlanner.freeGaps(now: date(12, 50), duration: 25, busy: meetings, dayEnd: date(22))
        // 12:55–13:00 is too short; 14:05–14:30 fits 25′; then 16:00 until the end of the day.
        XCTAssertEqual(gaps.map(\.start), [date(14, 5), date(16)])
        XCTAssertEqual(gaps.last?.end, date(22))
    }

    func testGapChipsOnlyWhereOwnSlotsMiss() {
        let now = date(12)
        let meetings = [busy(14, 0, 15, 0), busy(15, 30, 16, 30)]
        let own = CheckInPlanner.timeOptions(now: now, slots: [14 * 60, 15 * 60 + 30, 17 * 60])
        let gaps = CheckInPlanner.gapOptions(now: now, duration: 25, busy: meetings, existing: own)
        // 14:00 and 15:30 land on meetings, so 12:05–14:00 and 15:00–15:30 get their own chips.
        // 17:00 is free and inside 16:30–22:00, so that gap adds nothing.
        XCTAssertEqual(gaps.map(\.label), ["12:05", "15:00"])
        XCTAssertTrue(gaps.allSatisfy(\.isGap))
    }

    func testPreferredTimeSkipsBusySlots() {
        let now = date(12)
        let options = CheckInPlanner.timeOptions(now: now, slots: [14 * 60, 15 * 60 + 30])
        let picked = CheckInPlanner.preferredTime(options, duration: 25, busy: [busy(13, 50, 14, 30)], now: now)
        XCTAssertEqual(picked?.label, "15:30")
    }

    // MARK: Nếu lỡ giờ thì…

    func testSentenceCarriesTheCopingPlan() {
        let time = TimeOption(id: "14:00", label: "14:00", date: date(14))
        XCTAssertEqual(
            CheckInPlanner.sentence(task: "Đọc sách", time: time, duration: 25, coping: .shorter),
            "Lúc 14:00, mình sẽ đọc sách trong 25 phút. Nếu lỡ giờ, mình sẽ làm bản rút gọn 10 phút."
        )
    }

    func testRetimedSentenceNamesTheDay() {
        let now = date(15)
        XCTAssertEqual(
            CheckInPlanner.sentence(task: "Đọc sách", at: date(16, 10), duration: 25, coping: nil, now: now),
            "Lúc 16:10, mình sẽ đọc sách trong 25 phút."
        )
        XCTAssertEqual(
            CheckInPlanner.sentence(task: "Đọc sách", at: date(14, dayOffset: 1), duration: nil, coping: .evening, now: now),
            "Mai lúc 14:00, mình sẽ đọc sách. Nếu lỡ giờ, mình sẽ làm vào buổi tối."
        )
    }

    func testCheckInSavesTheCopingPlan() throws {
        let context = Persistence.makeContainer(inMemory: true).mainContext
        let plan = CheckInService.Plan(
            morningItems: [], mood: .ok,
            task: AfternoonSuggestion(title: "Đi bộ", category: nil, source: .manual),
            time: TimeOption(id: "17:00", label: "17:00", date: date(17)),
            durationMinutes: 15, coping: .nextGap
        )
        let task = try XCTUnwrap(CheckInService.save(plan, in: context))
        XCTAssertEqual(task.coping, .nextGap)
        XCTAssertEqual(task.ifThenSentence,
                       "Lúc 17:00, mình sẽ đi bộ trong 15 phút. Nếu lỡ giờ, mình sẽ dời sang khoảng trống kế tiếp.")
    }

    // MARK: Lỡ giờ

    func testMissedAfterGraceOnlyWhenNotStarted() {
        let task = TaskItem(title: "Đọc sách", category: nil, plannedAt: date(14), durationMinutes: 25, source: .manual)
        XCTAssertFalse(TodayList.isMissed(task, now: date(14, 5)), "still within the grace period")
        XCTAssertTrue(TodayList.isMissed(task, now: date(14, 15)))
        task.statusRaw = TaskStatus.doing.rawValue
        XCTAssertFalse(TodayList.isMissed(task, now: date(14, 15)), "started")
    }

    func testShortVersionStartsNowForTenMinutes() throws {
        let context = Persistence.makeContainer(inMemory: true).mainContext
        let task = TaskItem(title: "Viết test", category: nil, plannedAt: date(14), durationMinutes: 45, source: .manual)
        task.ifThenSentence = "Lúc 14:00, mình sẽ viết test trong 45 phút."
        task.coping = .shorter
        context.insert(task)

        TaskActions.startShortVersion(task, now: date(14, 20))
        XCTAssertEqual(task.status, .doing)
        XCTAssertEqual(task.durationMinutes, CopingPlan.shortMinutes)
        XCTAssertEqual(task.plannedAt, date(14, 20))
        XCTAssertEqual(task.ifThenSentence,
                       "Lúc 14:20, mình sẽ viết test trong 10 phút. Nếu lỡ giờ, mình sẽ làm bản rút gọn 10 phút.")
    }

    // MARK: Vẫn muốn làm?

    func testStaleAfterThreeMovesOrThreeDays() {
        let now = date(10)
        let moved = TaskItem(title: "Dọn email", category: nil, plannedAt: date(9), durationMinutes: nil, source: .manual)
        moved.postponeCount = 3
        XCTAssertTrue(TodayList.isStale(moved, now: now))

        let old = TaskItem(title: "Sửa xe", category: nil, plannedAt: nil, durationMinutes: nil, source: .manual)
        old.createdAt = date(9, dayOffset: -3)
        XCTAssertTrue(TodayList.isStale(old, now: now))

        let linked = TaskItem(title: "Review PR #42", category: nil, plannedAt: nil, durationMinutes: nil, source: .integration)
        linked.createdAt = date(9, dayOffset: -10)
        XCTAssertFalse(TodayList.isStale(linked, now: now), "GitHub / Jira work follows its source")
    }

    func testKeepingResetsTheCount() {
        let now = date(10)
        let task = TaskItem(title: "Sửa xe", category: nil, plannedAt: nil, durationMinutes: nil, source: .manual)
        task.createdAt = date(9, dayOffset: -5)
        task.postponeCount = 4
        TaskActions.keep(task, now: now)
        XCTAssertFalse(TodayList.isStale(task, now: now))
        XCTAssertTrue(TodayList.isStale(task, now: date(10, dayOffset: 3)), "asked again after three more days")
    }

    func testStaleWorkSinksToTheBottom() {
        let now = date(10)
        let stale = TaskItem(title: "Cũ", category: nil, plannedAt: nil, durationMinutes: nil, source: .manual)
        stale.createdAt = date(8, dayOffset: -4)
        let fresh = TaskItem(title: "Mới", category: nil, plannedAt: nil, durationMinutes: nil, source: .manual)
        fresh.createdAt = date(8)
        XCTAssertEqual(TodayList.tasks([stale, fresh], now: now).map(\.title), ["Mới", "Cũ"])
    }

    func testPostponingCounts() async {
        let context = Persistence.makeContainer(inMemory: true).mainContext
        let task = TaskItem(title: "Đọc sách", category: nil, plannedAt: date(14), durationMinutes: 25, source: .manual)
        context.insert(task)
        await TaskActions.postponeToTomorrow(task, serverPushActive: true, now: date(21))
        XCTAssertEqual(task.postponeCount, 1)
        XCTAssertEqual(task.plannedAt, date(14, dayOffset: 1))
    }

    // MARK: Khép lại hôm nay

    func testClosingTheDayKeepsTheNoonFeeling() throws {
        let context = Persistence.makeContainer(inMemory: true).mainContext
        CheckInService.save(.init(morningItems: [], mood: .good, task: nil, time: nil, durationMinutes: nil), in: context)
        CheckInService.closeDay(mood: .empty, moodLabel: "Trống", in: context)
        let checkIn = try XCTUnwrap(CheckInService.todaysCheckIn(context))
        XCTAssertNotNil(checkIn.closedAt)
        XCTAssertEqual(checkIn.mood, .good, "noon feeling unchanged")
        XCTAssertEqual(checkIn.dayMood, .empty)
        XCTAssertEqual(checkIn.dayMoodLabel, "Trống")
    }

    func testShutdownWaitsForALatePlan() {
        let now = date(12)
        let set = AppSettings.shutdownTime(on: now)
        let early = TaskItem(title: "Sớm", category: nil, plannedAt: set.addingTimeInterval(-3 * 3600),
                             durationMinutes: 25, source: .manual)
        XCTAssertEqual(NotificationService.shutdownTimeToday(open: [early], now: now), set)

        let late = TaskItem(title: "Muộn", category: nil, plannedAt: set, durationMinutes: 30, source: .manual)
        let expected = min(set.addingTimeInterval(45 * 60), date(23, 30))
        XCTAssertEqual(NotificationService.shutdownTimeToday(open: [early, late], now: now), expected,
                       "15 minutes after the last plan ends, like the per-task check did")
    }

    func testShutdownBodyNamesWhatIsOpen() {
        let tasks = ["Đọc sách", "Viết test", "Đi bộ", "Gọi mẹ"].map {
            TaskItem(title: $0, category: nil, plannedAt: nil, durationMinutes: nil, source: .manual)
        }
        XCTAssertEqual(Copy.shutdownBody(Array(tasks.prefix(2))),
                       "Còn 2 việc: Đọc sách, Viết test. Chạm để xếp, nhấn giữ để dời hết sang mai.")
        XCTAssertTrue(Copy.shutdownBody(tasks).hasPrefix("Còn 4 việc: Đọc sách, Viết test, Đi bộ…"))
        XCTAssertEqual(Copy.shutdownBody([]), "Không còn việc dang dở. Chạm để ghi cảm nhận cả ngày.")
    }

    func testMovingTheRestLeavesLinkedWorkAlone() async throws {
        let context = Persistence.makeContainer(inMemory: true).mainContext
        let now = Date()
        let planned = TaskItem(title: "Đọc sách", category: nil, plannedAt: DayClock.startOfDay(now),
                               durationMinutes: 25, source: .manual)
        let linked = TaskItem(title: "Review PR #42", category: nil, plannedAt: nil, durationMinutes: nil, source: .integration)
        [planned, linked].forEach(context.insert)

        await TaskActions.closeDayMovingRest(in: context, serverPushActive: true, now: now)
        XCTAssertFalse(DayClock.calendar.isDate(try XCTUnwrap(planned.plannedAt), inSameDayAs: now), "moved to tomorrow")
        XCTAssertNil(linked.plannedAt, "GitHub / Jira work follows its source")
        XCTAssertNotNil(CheckInService.todaysCheckIn(context, now: now)?.closedAt)
    }

    func testStateOfMindMapping() {
        XCTAssertGreaterThan(HealthService.valence(.good), HealthService.valence(.ok))
        XCTAssertGreaterThan(HealthService.valence(.ok), HealthService.valence(.empty))
        XCTAssertTrue((-1...1).contains(HealthService.valence(.empty)))
    }
}
