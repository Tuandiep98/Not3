import SwiftData
import XCTest
@testable import Not3

@MainActor
final class PersistenceTests: XCTestCase {
    func testLegacySingleStoreMovesIntoSplitStores() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appending(path: "default.store")

        // Phase-1 layout: every model in one store.
        let folderId: UUID
        let taskId: UUID
        do {
            let legacy = try ModelContainer(
                for: Persistence.schema,
                configurations: [ModelConfiguration(schema: Persistence.schema, url: legacyURL, cloudKitDatabase: .none)]
            )
            let context = ModelContext(legacy)
            let folder = Folder(name: "Học ngôn ngữ", sortOrder: 1)
            folderId = folder.id
            context.insert(folder)
            let note = Note(folder: folder)
            note.title = "Từ vựng tuần 44"
            note.categories = ["Học ngôn ngữ"]
            context.insert(note)
            let item = ChecklistItem(text: "deadline", order: 0)
            item.note = note
            item.isDone = true
            context.insert(item)
            let task = TaskItem(title: "Đi bộ", category: "Sức khoẻ", plannedAt: Date(), durationMinutes: 15, source: .manual)
            task.status = .done
            taskId = task.id
            context.insert(task)
            let checkIn = CheckIn(day: DayClock.startOfDay())
            checkIn.mood = .good
            context.insert(checkIn)
            context.insert(Chip(group: .category, label: "Sức khoẻ", isBuiltIn: true))
            try context.save()
        }

        let split = Persistence.makeContainer(inMemory: true)
        try Persistence.migrateLegacyStore(at: legacyURL, into: split)

        let context = ModelContext(split)
        let notes = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.title, "Từ vựng tuần 44")
        XCTAssertEqual(notes.first?.folder?.id, folderId, "note keeps its folder")
        XCTAssertEqual(notes.first?.sortedChecklist.map(\.isDone), [true])
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.map(\.id), [taskId])
        XCTAssertEqual(tasks.first?.status, .done)
        XCTAssertNotNil(tasks.first?.completedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CheckIn>()).first?.mood, .good)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Chip>()), 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path), "old file renamed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path + ".migrated"))
    }

    func testMergeDuplicateFoldersKeepsNotes() throws {
        let container = Persistence.makeContainer(inMemory: true)  // keep alive for the whole test
        let context = container.mainContext
        let a = Folder(name: "Công việc", sortOrder: 0)
        let b = Folder(name: "Công việc", sortOrder: 0)
        b.createdAt = a.createdAt.addingTimeInterval(10)
        context.insert(a)
        context.insert(b)
        let note = Note(folder: b)
        context.insert(note)
        try context.save()

        Persistence.mergeDuplicateFolders(context)

        let folders = try context.fetch(FetchDescriptor<Folder>())
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(note.folder?.id, a.id)
    }
}
