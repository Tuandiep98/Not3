import EventKit
import Foundation
import Observation
import SwiftData

/// Apple Reminders, on device only (module "Lời nhắc", off until turned on in Settings).
/// - Reminders due today (and overdue) become tasks in "Hôm nay"; undated ones can go to "Hộp chờ".
/// - Two-way: ticking the task completes the reminder and the other way round; deleting the
///   reminder cancels the task. Whichever side changed last wins.
/// - Reminders ticked today in the Reminders app (not imported as tasks) → morning / journal items.
@MainActor
@Observable
final class RemindersService {
    static let shared = RemindersService()

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private static let importedKey = "module.reminders.imported"
    private static let importedLimit = 500

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }
    private(set) var isAuthorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess

    /// Asked only when the user turns the module on.
    @discardableResult
    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        isAuthorized = granted
        if granted { startObserving() }
        return granted
    }

    func startObserving() {
        guard isAuthorized, LocalModule.isEnabled(.reminders), observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { _ in
            Task { @MainActor in
                await RemindersService.shared.refresh(in: Persistence.shared.mainContext)
            }
        }
    }

    /// Lists offered in Settings → Lời nhắc.
    func lists() -> [EKCalendar] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .reminder).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func readableLists() -> [EKCalendar] {
        let excluded = LocalModule.excluded(.reminders)
        return lists().filter { !excluded.contains($0.calendarIdentifier) }
    }

    // MARK: Refresh

    func refresh(in context: ModelContext, now: Date = Date()) async {
        guard LocalModule.isEnabled(.reminders), isAuthorized else { return }
        startObserving()
        await reconcile(in: context, now: now)
        let lists = readableLists()
        if !lists.isEmpty {
            await importOpen(from: lists, in: context, now: now)
            await importCompleted(from: lists, in: context, now: now)
        }
        try? context.save()
    }

    /// Open reminders → tasks, once each (a task the user deleted is not brought back).
    private func importOpen(from lists: [EKCalendar], in context: ModelContext, now: Date) async {
        let dueToday = LocalModule.isOn("due_today", for: .reminders)
        let noDue = LocalModule.isOn("no_due", for: .reminders)
        guard dueToday || noDue else { return }
        let open = await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists))
        var imported = Self.imported
        let linked = Set(linkedTasks(in: context).compactMap(\.reminderId))
        let end = DayClock.endOfDay(now)
        for reminder in open where !imported.contains(reminder.id) && !linked.contains(reminder.id) {
            let task: TaskItem
            if let due = reminder.due {
                guard dueToday, due < end else { continue }
                task = TaskItem(title: reminder.title, category: nil,
                                plannedAt: reminder.dueHasTime ? due : nil, durationMinutes: nil, source: .manual)
            } else {
                guard noDue else { continue }
                task = TaskItem(title: reminder.title, category: nil, plannedAt: nil, durationMinutes: nil, source: .manual)
                task.isSomeday = true
            }
            task.reminderId = reminder.id
            context.insert(task)
            imported.append(reminder.id)
        }
        Self.imported = imported
    }

    /// Reminders ticked today that are not tasks here → "Buổi sáng" / Nhật ký items.
    private func importCompleted(from lists: [EKCalendar], in context: ModelContext, now: Date) async {
        let start = DayClock.startOfDay(now)
        let end = DayClock.endOfDay(now)
        let raw = ExternalSource.reminders.rawValue
        let existing = (try? context.fetch(FetchDescriptor<ExternalItem>(predicate: #Predicate {
            $0.sourceRaw == raw && $0.occurredAt >= start && $0.occurredAt < end
        }))) ?? []
        var byId = Dictionary(existing.map { ($0.externalId, $0) }, uniquingKeysWith: { first, _ in first })
        if LocalModule.isOn("completed", for: .reminders) {
            let linked = Set(linkedTasks(in: context).compactMap(\.reminderId))
            let done = await fetch(store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: end, calendars: lists))
            for reminder in done where !linked.contains(reminder.id) {
                let at = reminder.completedAt ?? now
                if let item = byId.removeValue(forKey: reminder.id) {
                    item.title = reminder.title
                    item.occurredAt = at
                } else {
                    let item = ExternalItem(source: .reminders, externalId: reminder.id, title: reminder.title, url: nil, occurredAt: at)
                    item.kind = "completed"
                    context.insert(item)
                }
            }
        }
        // Unticked again, or the option was turned off.
        byId.values.forEach(context.delete)
    }

    // MARK: Two-way completion

    /// Open tasks from reminders, plus those finished in the last two days.
    private func linkedTasks(in context: ModelContext) -> [TaskItem] {
        let cancelled = TaskStatus.cancelled.rawValue
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.reminderId != nil && $0.statusRaw != cancelled
        }))) ?? []
        let recent = Date().addingTimeInterval(-2 * 86_400)
        return tasks.filter { $0.status != .done || ($0.completedAt ?? .distantPast) > recent }
    }

    private func reminder(id: String) -> EKReminder? {
        store.calendarItems(withExternalIdentifier: id).compactMap { $0 as? EKReminder }.first
    }

    private func reconcile(in context: ModelContext, now: Date) async {
        let serverPush = SupabaseService.shared.hasServerPush
        for task in linkedTasks(in: context) {
            guard let id = task.reminderId else { continue }
            guard let reminder = reminder(id: id) else {
                // Deleted in Reminders: the task goes too (like a deleted calendar event).
                if task.status != .done { task.status = .cancelled }
                continue
            }
            let taskDone = task.status == .done
            guard reminder.isCompleted != taskDone else { continue }
            if reminder.isCompleted {
                let completedAt = reminder.completionDate ?? now
                if completedAt >= task.updatedAt {
                    await TaskActions.setDone(task, true, serverPushActive: serverPush)
                    task.completedAt = completedAt
                } else {
                    save(reminder, completed: false)
                }
            } else {
                let changedAt = reminder.lastModifiedDate ?? .distantPast
                if (task.completedAt ?? .distantPast) >= changedAt {
                    save(reminder, completed: true)
                } else {
                    await TaskActions.setDone(task, false, serverPushActive: serverPush)
                }
            }
        }
    }

    /// Ticking / unticking a task from a reminder in Not3 → the reminder right away.
    func pushCompletion(of task: TaskItem) {
        guard isAuthorized, LocalModule.isEnabled(.reminders), let id = task.reminderId,
              let reminder = reminder(id: id) else { return }
        let done = task.status == .done
        if reminder.isCompleted != done { save(reminder, completed: done) }
    }

    private func save(_ reminder: EKReminder, completed: Bool) {
        reminder.isCompleted = completed
        try? store.save(reminder, commit: true)
    }

    // MARK: Fetching

    /// What the app keeps of a reminder (EKReminder is not Sendable).
    struct Snapshot: Sendable {
        let id: String
        let title: String
        let due: Date?
        let dueHasTime: Bool
        let completedAt: Date?

        init(_ reminder: EKReminder) {
            id = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
            title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Lời nhắc"
            due = reminder.dueDateComponents.flatMap { DayClock.calendar.date(from: $0) }
            dueHasTime = reminder.dueDateComponents?.hour != nil
            completedAt = reminder.completionDate
        }
    }

    private func fetch(_ predicate: NSPredicate) async -> [Snapshot] {
        await withCheckedContinuation { continuation in
            Self.fetch(store, predicate) { continuation.resume(returning: $0) }
        }
    }

    /// Nonisolated so the EventKit callback (on its own queue) is not tied to the main actor.
    nonisolated private static func fetch(_ store: EKEventStore, _ predicate: NSPredicate,
                                          done: @escaping @Sendable ([Snapshot]) -> Void) {
        store.fetchReminders(matching: predicate) { reminders in
            done((reminders ?? []).map(Snapshot.init))
        }
    }

    private static var imported: [String] {
        get { UserDefaults.standard.stringArray(forKey: importedKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(importedLimit)), forKey: importedKey) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
