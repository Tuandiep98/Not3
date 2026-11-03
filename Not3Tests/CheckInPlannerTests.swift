import SwiftData
import XCTest
@testable import Not3

@MainActor
final class CheckInPlannerTests: XCTestCase {
    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        DayClock.at(hour: hour, minute: minute, on: DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!)
    }

    func testTimeOptionsDropPastSlots() {
        let labels = CheckInPlanner.timeOptions(now: date(15, 0)).map(\.label)
        XCTAssertEqual(labels, ["15:30", "17:00", "Tối nay"])
    }

    func testTimeOptionsAtNoon() {
        let labels = CheckInPlanner.timeOptions(now: date(12, 0)).map(\.label)
        XCTAssertEqual(labels, ["14:00", "15:30", "17:00", "Tối nay"])
    }

    func testTimeOptionsUseCustomSlots() {
        let labels = CheckInPlanner.timeOptions(now: date(12, 0), slots: [16 * 60 + 45, 13 * 60]).map(\.label)
        XCTAssertEqual(labels, ["13:00", "16:45", "Tối nay"])
    }

    func testIntListSortsAndDropsDuplicates() {
        XCTAssertEqual(IntList.decode("45,15,x,15,60"), [15, 45, 60])
        XCTAssertEqual(IntList.encode([60, 25, 25]), "25,60")
        XCTAssertEqual(IntList.decode(""), [])
    }

    func testChipStoreListLimits() {
        XCTAssertEqual(ChipStore.adding(30, to: "15,25"), "15,25,30")
        XCTAssertNil(ChipStore.adding(25, to: "15,25"), "duplicate")
        XCTAssertNil(ChipStore.adding(90, to: "5,10,15,20,25,30"), "row full")
        XCTAssertEqual(ChipStore.removing(25, from: "15,25,45"), "15,45")
        XCTAssertEqual(ChipStore.slotLabel(15 * 60 + 5), "15:05")
    }

    func testCategoryNameValidation() {
        let work = Chip(group: .category, label: "Công việc", isBuiltIn: true)
        XCTAssertFalse(ChipStore.isValidName("  ", editing: nil, among: [work]))
        XCTAssertFalse(ChipStore.isValidName("công việc", editing: nil, among: [work]))
        XCTAssertTrue(ChipStore.isValidName("Công việc", editing: work, among: [work]))
        XCTAssertTrue(ChipStore.isValidName("Thiền", editing: nil, among: [work]))
    }

    func testRenamedWorkCategoryStillComesLast() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let chips = ChipCatalog.defaultCategories.map { Chip(group: .category, label: $0, isBuiltIn: true) }
        chips.forEach(context.insert)
        let work = try XCTUnwrap(chips.first { $0.isWork })
        ChipStore.save(ChipDraft(name: "Công ty"), group: .category, editing: work, in: context)

        XCTAssertEqual(ChipStore.workCategoryName(in: context), "Công ty")
        let result = CheckInPlanner.suggestions(categories: chips, recentTasks: [], now: date(12))
        XCTAssertFalse(result.contains { $0.category == "Công ty" }, "self-development first")

        ChipStore.save(ChipDraft(name: "Công việc"), group: .category, editing: nil, in: context)
        let flagged = try context.fetch(FetchDescriptor<Chip>()).filter(\.isWork).map(\.label)
        XCTAssertEqual(flagged, ["Công ty"], "a new \"Công việc\" does not take the flag")
    }

    func testCustomFeelingIsSavedWithItsLevel() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        ChipStore.seedMoods(in: context)
        let focused = ChipStore.save(ChipDraft(name: "Tập trung", level: .good, symbol: "target"),
                                     group: .mood, editing: nil, in: context)

        let options = ChipStore.moodOptions(try context.fetch(FetchDescriptor<Chip>()))
        XCTAssertEqual(options.first?.label, Mood.good.label, "built-in first within a level")
        XCTAssertTrue(options.contains { $0.label == "Tập trung" && $0.level == .good })

        let plan = CheckInService.Plan(morningItems: [], mood: focused.level, moodLabel: focused.label,
                                       task: nil, time: nil, durationMinutes: nil)
        CheckInService.save(plan, in: context)
        let checkIn = try XCTUnwrap(CheckInService.todaysCheckIn(context))
        XCTAssertEqual(checkIn.moodRaw, "good", "server still gets the level")
        XCTAssertEqual(checkIn.moodText, "Tập trung")
    }

    func testQuickAnswerUsesRenamedBuiltInFeeling() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        ChipStore.seedMoods(in: context)
        let good = try XCTUnwrap(try context.fetch(FetchDescriptor<Chip>()).first { $0.level == .good })
        ChipStore.save(ChipDraft(name: "Năng suất", level: .good), group: .mood, editing: good, in: context)

        CheckInService.recordMood(.good, in: context)
        XCTAssertEqual(CheckInService.todaysCheckIn(context)?.moodText, "Năng suất")
    }

    func testCategoryAddedInSettingsShowsBeforeFirstUse() {
        let chip = Chip(group: .category, label: "Thiền", isBuiltIn: false)
        XCTAssertEqual(CheckInPlanner.rankedCategories([chip]).map(\.label), ["Thiền"])
    }

    func testIfThenSentence() {
        let time = TimeOption(id: "14:00", label: "14:00", date: date(14))
        XCTAssertEqual(
            CheckInPlanner.sentence(task: "Học 20 từ vựng Anki", time: time, duration: 25),
            "Lúc 14:00, mình sẽ học 20 từ vựng Anki trong 25 phút."
        )
        let evening = TimeOption(id: "evening", label: "Tối nay", date: date(20))
        XCTAssertEqual(
            CheckInPlanner.sentence(task: "Đi bộ", time: evening, duration: nil),
            "Tối nay, mình sẽ đi bộ."
        )
    }

    func testSuggestionsPreferMissingNonWorkCategories() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let chips = ChipCatalog.defaultCategories.map { Chip(group: .category, label: $0, isBuiltIn: true) }
        chips.forEach(context.insert)

        let now = date(12)
        let done = TaskItem(title: "Học 20 từ vựng Anki", category: "Học ngôn ngữ", plannedAt: nil, durationMinutes: 25, source: .manual)
        context.insert(done)
        done.status = .done

        let result = CheckInPlanner.suggestions(categories: chips, recentTasks: [done], now: now)
        XCTAssertEqual(result.count, 3)
        XCTAssertFalse(result.contains { $0.category == "Học ngôn ngữ" }, "category used this week should not lead")
        XCTAssertFalse(result.contains { $0.category == ChipCatalog.workCategory }, "self-development first")
    }

    func testMeaningfulDay() {
        let task = TaskItem(title: "Viết test", category: "Công việc", plannedAt: nil, durationMinutes: 45, source: .manual)
        XCTAssertFalse(CheckInPlanner.isMeaningful(day: Date(), tasks: [task]))
        task.status = .done
        XCTAssertTrue(CheckInPlanner.isMeaningful(day: Date(), tasks: [task]))
    }

    func testSaveCheckInCreatesPlannedTask() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let plan = CheckInService.Plan(
            morningItems: ["Review PR #42"],
            mood: .good,
            task: AfternoonSuggestion(title: "Đi bộ", category: "Sức khoẻ", source: .manual),
            time: TimeOption(id: "17:00", label: "17:00", date: date(17)),
            durationMinutes: 15
        )
        let task = try XCTUnwrap(CheckInService.save(plan, in: context))
        XCTAssertEqual(task.ifThenSentence, "Lúc 17:00, mình sẽ đi bộ trong 15 phút.")
        let checkIn = try XCTUnwrap(CheckInService.todaysCheckIn(context))
        XCTAssertEqual(checkIn.mood, .good)
        XCTAssertEqual(checkIn.afternoonTaskIds, [task.id])
        let chips = try context.fetch(FetchDescriptor<Chip>())
        XCTAssertTrue(chips.contains { $0.label == "Sức khoẻ" && $0.useCount == 1 })
    }

    func testChoosingUnfinishedMorningTaskReschedulesItInsteadOfCopying() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let morning = TaskItem(title: "Review PR #42", category: "Công việc", plannedAt: date(9), durationMinutes: nil, source: .integration)
        context.insert(morning)
        try context.save()

        let plan = CheckInService.Plan(
            morningItems: [],
            mood: .empty,
            task: AfternoonSuggestion(title: morning.title, category: morning.category, source: .integration, taskId: morning.id),
            time: TimeOption(id: "15:30", label: "15:30", date: date(15, 30)),
            durationMinutes: 25
        )
        let saved = try XCTUnwrap(CheckInService.save(plan, in: context))
        XCTAssertEqual(saved.id, morning.id, "same task, not a copy")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), 1)
        XCTAssertEqual(saved.plannedAt, date(15, 30))
        XCTAssertEqual(saved.durationMinutes, 25)
        XCTAssertEqual(saved.ifThenSentence, "Lúc 15:30, mình sẽ review PR #42 trong 25 phút.")
        XCTAssertEqual(CheckInService.todaysCheckIn(context)?.afternoonTaskIds, [morning.id])
    }
}
