import Foundation
import SwiftData

/// Two stores (README §7):
/// - `notes.store`  — Folder / Note / ChecklistItem, synced through the user's private CloudKit DB.
/// - `local.store`  — tasks, repeating series, check-ins, chips, external items: source of truth is Supabase,
///                    so they stay on device (SwiftData = offline cache).
enum Persistence {
    static let cloudKitContainer = "iCloud.com.tuandiep.not3"

    static let noteModels: [any PersistentModel.Type] = [Folder.self, Note.self, ChecklistItem.self]
    static let localModels: [any PersistentModel.Type] = [TaskItem.self, TaskSeries.self, CheckIn.self, Chip.self, ExternalItem.self]
    static let schema = Schema(noteModels + localModels)

    /// Shared container so notification actions handled in the AppDelegate write to the same store.
    static let shared: ModelContainer = makeContainer(inMemory: false)

    /// Whether notes are actually syncing through iCloud (false after a fallback).
    nonisolated(unsafe) private(set) static var isCloudKitActive = false

    static func makeContainer(inMemory: Bool) -> ModelContainer {
        if inMemory {
            let configurations = [
                ModelConfiguration("Notes", schema: Schema(noteModels), isStoredInMemoryOnly: true, cloudKitDatabase: .none),
                ModelConfiguration("Local", schema: Schema(localModels), isStoredInMemoryOnly: true, cloudKitDatabase: .none),
            ]
            do {
                return try ModelContainer(for: schema, configurations: configurations)
            } catch {
                fatalError("Không tạo được ModelContainer: \(error)")
            }
        }

        // "Đồng bộ iCloud" switch (takes effect on next launch).
        let wantsCloud = cloudKitAllowed && (UserDefaults.standard.object(forKey: SettingsKey.iCloudSync) as? Bool ?? true)

        // CloudKit can be unavailable (missing entitlement, restricted account…): fall back to a
        // local notes store instead of crashing. Same file, so nothing is lost when sync returns.
        for cloud in wantsCloud ? [true, false] : [false] {
            do {
                let container = try ModelContainer(for: schema, configurations: fileConfigurations(cloud: cloud))
                isCloudKitActive = cloud
                migrateLegacyStore(into: container)
                return container
            } catch {
                continue
            }
        }
        fatalError("Không tạo được ModelContainer")
    }

    /// CloudKit traps (not a catchable error) when the build lacks a valid iCloud entitlement —
    /// unsigned simulator builds and XCTest hosts. Only signed device builds sync notes.
    private static var cloudKitAllowed: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #endif
    }

    private static func fileConfigurations(cloud: Bool) -> [ModelConfiguration] {
        let directory = URL.applicationSupportDirectory
        return [
            ModelConfiguration(
                "Notes",
                schema: Schema(noteModels),
                url: directory.appending(path: "notes.store"),
                cloudKitDatabase: cloud ? .private(cloudKitContainer) : .none
            ),
            ModelConfiguration(
                "Local",
                schema: Schema(localModels),
                url: directory.appending(path: "local.store"),
                cloudKitDatabase: .none
            ),
        ]
    }

    // MARK: One-time move from the single phase-1 store (default.store)

    private static let migratedKey = "migratedToSplitStores"

    private static func migrateLegacyStore(into container: ModelContainer) {
        let legacyURL = URL.applicationSupportDirectory.appending(path: "default.store")
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        do {
            try migrateLegacyStore(at: legacyURL, into: container)
            defaults.set(true, forKey: migratedKey)
        } catch {
            // Leave the flag unset: the next launch tries again; the new stores still work.
        }
    }

    /// Copies everything from a phase-1 single store into the split stores, then renames the old
    /// file to `*.migrated` as a backup. No-op when the file does not exist.
    static func migrateLegacyStore(at legacyURL: URL, into container: ModelContainer) throws {
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        // Scope the legacy container so its files are closed before they are renamed.
        try {
            let legacy = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: legacyURL, cloudKitDatabase: .none)]
            )
            try copy(from: ModelContext(legacy), to: ModelContext(container))
        }()
        for suffix in ["", "-shm", "-wal"] {
            let from = URL(filePath: legacyURL.path + suffix)
            let to = URL(filePath: legacyURL.path + ".migrated" + suffix)
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.moveItem(at: from, to: to)
        }
    }

    private static func copy(from old: ModelContext, to new: ModelContext) throws {
        var folders: [UUID: Folder] = [:]
        for f in try old.fetch(FetchDescriptor<Folder>()) {
            let copy = Folder(name: f.name, sortOrder: f.sortOrder)
            copy.id = f.id
            copy.createdAt = f.createdAt
            new.insert(copy)
            folders[f.id] = copy
        }
        for n in try old.fetch(FetchDescriptor<Note>()) {
            let copy = Note(folder: n.folder.flatMap { folders[$0.id] })
            copy.id = n.id
            copy.title = n.title
            copy.body = n.body
            copy.categories = n.categories
            copy.suggestedCategories = n.suggestedCategories
            copy.durationMinutes = n.durationMinutes
            copy.isPinned = n.isPinned
            copy.createdAt = n.createdAt
            copy.updatedAt = n.updatedAt
            copy.needsSync = n.needsSync
            new.insert(copy)
            for item in n.checklist ?? [] {
                let c = ChecklistItem(text: item.text, order: item.order)
                c.id = item.id
                c.isDone = item.isDone
                c.note = copy
                new.insert(c)
            }
        }
        for t in try old.fetch(FetchDescriptor<TaskItem>()) {
            let copy = TaskItem(title: t.title, category: t.category, plannedAt: t.plannedAt,
                                durationMinutes: t.durationMinutes, source: t.source)
            copy.id = t.id
            copy.statusRaw = t.statusRaw
            copy.ifThenSentence = t.ifThenSentence
            copy.createdAt = t.createdAt
            copy.updatedAt = t.updatedAt
            copy.completedAt = t.completedAt
            copy.calendarEventId = t.calendarEventId
            copy.isSomeday = t.isSomeday
            copy.seriesId = t.seriesId
            copy.needsSync = t.needsSync
            new.insert(copy)
        }
        for c in try old.fetch(FetchDescriptor<CheckIn>()) {
            let copy = CheckIn(day: c.day)
            copy.id = c.id
            copy.morningItems = c.morningItems
            copy.moodRaw = c.moodRaw
            copy.afternoonTaskIds = c.afternoonTaskIds
            copy.createdAt = c.createdAt
            copy.needsSync = c.needsSync
            new.insert(copy)
        }
        for c in try old.fetch(FetchDescriptor<Chip>()) {
            let copy = Chip(group: c.group, label: c.label, isBuiltIn: c.isBuiltIn)
            copy.id = c.id
            copy.useCount = c.useCount
            copy.lastUsedAt = c.lastUsedAt
            new.insert(copy)
        }
        // ExternalItems are re-imported from Calendar / the server; no need to copy.
        try new.save()
    }

    /// Seeds default folders and built-in chips on first launch.
    /// With iCloud on, another device may already have created the folders; duplicates by name are merged.
    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        let folderCount = (try? context.fetchCount(FetchDescriptor<Folder>())) ?? 0
        if folderCount == 0 && !UserDefaults.standard.bool(forKey: "seededFolders") {
            for (index, name) in ["Công việc", "Học ngôn ngữ", "Sở thích", "Ghi chú nhanh"].enumerated() {
                context.insert(Folder(name: name, sortOrder: index))
            }
        }
        UserDefaults.standard.set(true, forKey: "seededFolders")
        let chipCount = (try? context.fetchCount(FetchDescriptor<Chip>())) ?? 0
        if chipCount == 0 {
            for name in ChipCatalog.defaultCategories {
                context.insert(Chip(group: .category, label: name, isBuiltIn: true))
            }
        }
        try? context.save()
    }

    /// iCloud can deliver a second copy of a default folder created on another device.
    @MainActor
    static func mergeDuplicateFolders(_ context: ModelContext) {
        guard let folders = try? context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.createdAt)])) else { return }
        var keep: [String: Folder] = [:]
        for folder in folders {
            if let first = keep[folder.name] {
                for note in folder.notes ?? [] { note.folder = first }
                context.delete(folder)
            } else {
                keep[folder.name] = folder
            }
        }
        try? context.save()
    }
}

enum ChipCatalog {
    static let defaultCategories = ["Công việc", "Học ngôn ngữ", "Sở thích", "Sức khoẻ", "Đọc sách"]
    static let durations = [15, 25, 45, 60]
    /// Categories that count as "phát triển bản thân" for afternoon suggestions.
    static let workCategory = "Công việc"
    /// Max chips per row before the rest move behind "Thêm".
    static let maxPerRow = 6
}
