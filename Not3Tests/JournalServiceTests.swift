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

    func testRenderSplitsMorningAndAfternoon() {
        let text = JournalService.render([
            .init(time: at(9, 5), text: "GitHub: Review PR #42"),
            .init(time: at(14, 30), text: "✓ Học 20 từ vựng Anki"),
        ], now: at(20))
        XCTAssertEqual(text, [
            JournalService.beginMarker,
            "Sáng", "09:05  GitHub: Review PR #42",
            "Chiều", "14:30  ✓ Học 20 từ vựng Anki",
            JournalService.endMarker,
        ].joined(separator: "\n"))
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
    }
}
