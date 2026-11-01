import SwiftData
import XCTest
@testable import Not3

@MainActor
final class WidgetBridgeTests: XCTestCase {
    private let noon = DayClock.at(hour: 13, minute: 0, on: DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!)

    func testSnapshotCarriesTodayMorningPlanAndSources() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let review = TaskItem(title: "Review PR #42", category: "Công việc", plannedAt: nil, durationMinutes: nil, source: .integration)
        review.linkURL = "https://github.com/acme/app/pull/42"
        review.createdAt = noon
        context.insert(review)
        let plan = TaskItem(title: "Học Anki", category: "Học ngôn ngữ", plannedAt: DayClock.at(hour: 14, minute: 0, on: noon), durationMinutes: 25, source: .manual)
        plan.ifThenSentence = "Lúc 14:00, mình sẽ học Anki trong 25 phút."
        context.insert(plan)
        let checkIn = CheckIn(day: DayClock.startOfDay(noon))
        checkIn.mood = .good
        checkIn.afternoonTaskIds = [plan.id]
        context.insert(checkIn)
        context.insert(ExternalItem(source: .jira, externalId: "JIRA-118", title: "JIRA-118 → Done",
                                    url: nil, occurredAt: DayClock.at(hour: 10, minute: 40, on: noon)))
        context.insert(ExternalItem(source: .calendar, externalId: "later", title: "Họp 16:00",
                                    url: nil, occurredAt: DayClock.at(hour: 16, minute: 0, on: noon)))
        try context.save()

        let s = WidgetBridge.build(in: context, now: noon)
        XCTAssertEqual(s.mood, "good")
        XCTAssertEqual(s.plan?.sentence, "Lúc 14:00, mình sẽ học Anki trong 25 phút.")
        XCTAssertEqual(s.morning.map(\.title), ["JIRA-118 → Done"], "future calendar events are not part of the morning")
        XCTAssertEqual(Set(s.tasks.map(\.title)), ["Review PR #42", "Học Anki"])
        XCTAssertEqual(s.tasks.first { $0.title == "Review PR #42" }?.source, "github")
        XCTAssertEqual(s.folders.first?.id, WidgetSnapshot.allNotesID)
    }

    func testSnapshotRoundTripAndActionQueue() throws {
        var s = WidgetSnapshot.empty
        s.mood = "ok"
        let data = try JSONEncoder.widget.encode(s)
        XCTAssertEqual(try JSONDecoder.widget.decode(WidgetSnapshot.self, from: data), s)

        _ = WidgetAction.drain()   // start clean
        let id = UUID()
        WidgetAction(kind: .setTaskDone, taskId: id, done: true).enqueue()
        WidgetAction(kind: .recordMood, mood: "good").enqueue()
        let drained = WidgetAction.drain()
        XCTAssertEqual(drained.map(\.kind), [.setTaskDone, .recordMood], "oldest first")
        XCTAssertEqual(drained.first?.taskId, id)
        XCTAssertTrue(WidgetAction.drain().isEmpty, "files are removed once read")
    }
}
