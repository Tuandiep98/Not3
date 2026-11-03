import SwiftData
import XCTest
@testable import Not3

@MainActor
final class ExportServiceTests: XCTestCase {
    func testFileNamesAreSafeAndUnique() {
        var taken: Set<String> = []
        XCTAssertEqual(ExportService.fileName("Kế hoạch: Q4/2026?", taken: &taken), "Kế hoạch Q4 2026")
        XCTAssertEqual(ExportService.fileName("kế hoạch  q4 2026", taken: &taken), "kế hoạch q4 2026 2", "case-insensitive file systems")
        XCTAssertEqual(ExportService.fileName("  \n ", taken: &taken), "Ghi chú")
        XCTAssertEqual(ExportService.fileName("", taken: &taken), "Ghi chú 2")
        XCTAssertEqual(ExportService.fileName("..hidden.", taken: &taken), "hidden")
        XCTAssertEqual(ExportService.fileName(String(repeating: "a", count: 200), taken: &taken).count, 80)
    }

    func testNoteMarkdown() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let folder = Folder(name: "Công việc", sortOrder: 0)
        context.insert(folder)
        let note = Note(folder: folder)
        note.title = "Họp sprint"
        note.body = "Chốt phạm vi"
        note.categories = ["Công việc", "Họp: tuần"]
        note.createdAt = Date(timeIntervalSince1970: 1_793_000_000)
        note.updatedAt = note.createdAt
        context.insert(note)
        for (i, text) in ["Gửi biên bản", "Tạo ticket"].enumerated() {
            let item = ChecklistItem(text: text, order: i)
            item.isDone = i == 0
            item.note = note
            context.insert(item)
        }
        try context.save()

        let md = ExportService.markdown(for: note, photos: ["abc-1.jpg"])
        XCTAssertTrue(md.hasPrefix("---\ncreated: "))
        XCTAssertTrue(md.contains("folder: Công việc\n"))
        XCTAssertTrue(md.contains("tags: [Công việc, \"Họp: tuần\"]\n"), "values with ':' are quoted")
        XCTAssertTrue(md.contains("---\n\n# Họp sprint\n\nChốt phạm vi\n\n- [x] Gửi biên bản\n- [ ] Tạo ticket\n\n![](../../attachments/abc-1.jpg)\n"))
    }

    func testTaskLines() {
        let day = DayClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let task = TaskItem(title: "Học Anki", category: "Học ngôn ngữ", plannedAt: DayClock.at(hour: 14, minute: 0, on: day),
                            durationMinutes: 25, source: .manual)
        XCTAssertEqual(ExportService.taskLine(task), "- [ ] 14:00 Học Anki · 25 phút · Học ngôn ngữ")
        task.statusRaw = TaskStatus.cancelled.rawValue
        XCTAssertEqual(ExportService.taskLine(task), "- [-] 14:00 Học Anki · 25 phút · Học ngôn ngữ")

        let someday = TaskItem(title: "Đọc sách", category: nil, plannedAt: nil, durationMinutes: nil, source: .manual)
        someday.isSomeday = true
        let md = ExportService.tasksMarkdown([task, someday], now: day)
        XCTAssertTrue(md.contains("## Hộp chờ\n- [ ] Đọc sách\n"))
        XCTAssertTrue(md.contains("## 2026-11-02\n- [-] 14:00 Học Anki"))
    }
}
