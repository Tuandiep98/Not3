import AppIntents
import CoreSpotlight
import Foundation
import SwiftData

/// Notes and open tasks in Spotlight. Re-indexes only what changed after each SwiftData save
/// (debounced, like WidgetBridge) and removes what no longer exists.
@MainActor
enum SpotlightIndexer {
    static let domain = "com.tuandiep.not3"
    private static let signaturesKey = "spotlightSignatures"
    private static var observer: NSObjectProtocol?
    private static var pending: Task<Void, Never>?

    static func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            Task { @MainActor in SpotlightIndexer.updateSoon() }
        }
        update()
    }

    static func updateSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            update()
        }
    }

    static func update() {
        let context = Persistence.shared.mainContext
        var entries: [String: (signature: String, item: () -> CSSearchableItem)] = [:]
        // "Không hiện": nothing indexed; everything indexed before is removed below.
        let notes = AppSettings.spotlightPrivacy == .hidden ? [] : NoteEntityQuery.notes()
        for note in notes {
            entries[identifier(note: note.id)] = (signature(note), { item(for: note) })
        }
        let tasks = AppSettings.spotlightPrivacy == .hidden ? [] : (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        for task in tasks where task.status == .todo || task.status == .doing {
            entries[identifier(task: task.id)] = (signature(task), { item(for: task) })
        }

        let previous = UserDefaults.standard.dictionary(forKey: signaturesKey) as? [String: String] ?? [:]
        let changed = entries.filter { previous[$0.key] != $0.value.signature }.map { $0.value.item() }
        let removed = previous.keys.filter { entries[$0] == nil }
        guard !changed.isEmpty || !removed.isEmpty else { return }

        let index = CSSearchableIndex.default()
        if !changed.isEmpty { index.indexSearchableItems(changed) }
        if !removed.isEmpty { index.deleteSearchableItems(withIdentifiers: Array(removed)) }
        UserDefaults.standard.set(entries.mapValues(\.signature), forKey: signaturesKey)
        // Task names in Siri phrases ("Complete … in Not3").
        Not3Shortcuts.updateAppShortcutParameters()
    }

    // MARK: Items

    nonisolated static func identifier(note id: UUID) -> String { "note:\(id.uuidString)" }
    nonisolated static func identifier(task id: UUID) -> String { "task:\(id.uuidString)" }

    /// Spotlight result tapped → the app's own link.
    nonisolated static func deepLink(for identifier: String) -> URL? {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "note": return DeepLink.note(id)
        case "task": return DeepLink.task(id)
        default: return nil
        }
    }

    private static func signature(_ note: Note) -> String {
        "\(note.updatedAt.timeIntervalSince1970)|\(note.folder?.name ?? "")|\(AppSettings.spotlightPrivacy.rawValue)"
    }

    private static func signature(_ task: TaskItem) -> String {
        "\(task.updatedAt.timeIntervalSince1970)|\(task.statusRaw)|\(DayClock.isoDay(Date()))|\(AppSettings.spotlightPrivacy.rawValue)"
    }

    static func item(for note: Note) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = note.displayTitle
        // "Chỉ tiêu đề": the content stays in the app.
        if AppSettings.spotlightPrivacy == .full {
            attributes.contentDescription = [note.folder?.name, note.preview].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            attributes.textContent = ([note.body] + note.sortedChecklist.map(\.text)).joined(separator: "\n")
        }
        attributes.keywords = note.categories
        attributes.contentModificationDate = note.updatedAt
        let item = CSSearchableItem(uniqueIdentifier: identifier(note: note.id), domainIdentifier: "\(domain).notes", attributeSet: attributes)
        item.associateAppEntity(NoteEntity(note), priority: 1)
        return item
    }

    static func item(for task: TaskItem) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = task.title
        if AppSettings.spotlightPrivacy == .full { attributes.contentDescription = TaskEntity.detail(for: task) }
        attributes.keywords = [task.category, "việc"].compactMap { $0 }
        attributes.contentModificationDate = task.updatedAt
        let item = CSSearchableItem(uniqueIdentifier: identifier(task: task.id), domainIdentifier: "\(domain).tasks", attributeSet: attributes)
        item.associateAppEntity(TaskEntity(task), priority: 0)
        return item
    }
}
