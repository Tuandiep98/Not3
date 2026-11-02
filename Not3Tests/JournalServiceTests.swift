import SwiftData
import XCTest
@testable import Not3

@MainActor
final class JournalServiceTests: XCTestCase {
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        DayClock.at(hour: hour, minute: minute, on: DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!)
    }

    func testUserTextOutsideTheBlockIsKept() {
        let body = "Ý tưởng của mình\n\n\(JournalService.beginMarker)\ncũ\n\(JournalService.endMarker)\n\nGhi thêm cuối ngày"
        let merged = JournalService.replaceManagedBlock(in: body, with: "\(JournalService.beginMarker)\nmới\n\(JournalService.endMarker)")
        XCTAssertTrue(merged.hasPrefix("Ý tưởng của mình"))
        XCTAssertTrue(merged.hasSuffix("Ghi thêm cuối ngày"))
        XCTAssertTrue(merged.contains("mới"))
        XCTAssertFalse(merged.contains("cũ"))
    }

    func testBlockIsAppendedWhenMissing() {
        let merged = JournalService.replaceManagedBlock(in: "Chỉ có chữ của mình", with: "BLOCK")
        XCTAssertEqual(merged, "Chỉ có chữ của mình\n\nBLOCK")
    }

    func testRenderHasSummaryAndSymbolsPerKind() {
        let text = JournalService.render([
            .init(time: at(9, 5), text: "PR #42 đã merge", kind: .activity(.github)),
            .init(time: at(10), text: "Standup", kind: .meeting),
            .init(time: at(14, 30), text: "Học 20 từ vựng Anki", kind: .task),
        ], now: at(20))
        XCTAssertEqual(text, [
            JournalService.beginMarker,
            "Hôm nay: 1 việc xong · 1 cuộc họp · 1 hoạt động GitHub",
            "",
            "SÁNG · 2", "09:05  • GitHub · PR #42 đã merge", "10:00  ◷ Standup",
            "",
            "CHIỀU · 1", "14:30  ✓ Học 20 từ vựng Anki",
            JournalService.endMarker,
        ].joined(separator: "\n"))
    }

    func testLegacyBlockIsUpgradedInPlace() {
        let (open, close) = JournalService.legacyMarkers
        let merged = JournalService.replaceManagedBlock(in: "Đầu\n\(open)\ncũ\n\(close)\nCuối", with: "MỚI")
        XCTAssertEqual(merged, "Đầu\nMỚI\nCuối")
    }

    func testDoneTaskHidesItsLinkedItemAndIgnoredItemsStayOut() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let now = Date()
        let task = TaskItem(title: "Review PR #42", category: "Công việc", plannedAt: nil, durationMinutes: nil, source: .manual)
        task.linkURL = "https://github.com/o/r/pull/42"
        context.insert(task)
        task.status = .done
        let linked = ExternalItem(source: .github, externalId: "pr42", title: "PR #42", url: task.linkURL, occurredAt: now)
        let ignored = ExternalItem(source: .github, externalId: "c1", title: "bump deps", url: nil, occurredAt: now)
        ignored.decision = "ignored"
        let commit = ExternalItem(source: .github, externalId: "c2", title: "3 commit · app-ios", url: nil, occurredAt: now)
        [linked, ignored, commit].forEach(context.insert)
        let lines = JournalService.collect(in: context, now: now.addingTimeInterval(1)).map(\.line)
        XCTAssertEqual(Set(lines), ["✓ Review PR #42", "• GitHub · 3 commit · app-ios"])
        _ = container
    }

    func testUpdateTodayCreatesOneNoteInJournalFolder() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let task = TaskItem(title: "Đi bộ", category: "Sức khoẻ", plannedAt: nil, durationMinutes: 15, source: .manual)
        context.insert(task)
        task.status = .done
        JournalService.updateToday(in: context)
        JournalService.updateToday(in: context)   // idempotent
        let notes = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.folder?.name, JournalService.folderName)
        XCTAssertTrue(notes.first?.body.contains("✓ Đi bộ") == true)
        XCTAssertTrue(notes.first?.body.contains("Hôm nay: 1 việc xong") == true)
    }
}
