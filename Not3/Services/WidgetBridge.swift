import Foundation
import SwiftData
import WidgetKit

/// App side of the widgets: builds the snapshot from SwiftData, applies actions taken on widgets,
/// and reloads timelines whenever the data changes (any save, foreground, background refresh).
@MainActor
enum WidgetBridge {
    private static var observer: NSObjectProtocol?
    private static var pending: Task<Void, Never>?

    /// Rebuild the snapshot shortly after any SwiftData save (debounced), so every change —
    /// a tick in the app, a check-in, a GitHub / Jira sync — reaches the widgets.
    static func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            Task { @MainActor in WidgetBridge.publishSoon() }
        }
    }

    static func publishSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            publish()
        }
    }

    /// Writes the snapshot and reloads widgets only when the content actually changed
    /// (WidgetKit has a daily reload budget).
    static func publish(now: Date = Date()) {
        let context = Persistence.shared.mainContext
        var snapshot = build(in: context, now: now)
        let previous = WidgetSnapshot.load()
        snapshot.generatedAt = previous.generatedAt
        guard snapshot != previous else { return }
        snapshot.generatedAt = now
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
        WatchBridge.shared.send(snapshot)
    }

    // MARK: Actions from interactive widgets

    /// Applies ticks / moods / starts recorded by widgets while the app was not running.
    @discardableResult
    static func applyPendingActions(serverPushActive: Bool) async -> Int {
        let actions = WidgetAction.drain()
        guard !actions.isEmpty else { return 0 }
        let context = Persistence.shared.mainContext
        for action in actions {
            switch action.kind {
            case .setTaskDone:
                if let id = action.taskId, let task = TaskActions.task(id: id, in: context) {
                    await TaskActions.setDone(task, action.done ?? true, serverPushActive: serverPushActive)
                    if action.done ?? true { task.completedAt = action.at }
                }
            case .startTask:
                if let id = action.taskId, let task = TaskActions.task(id: id, in: context), task.status == .todo {
                    task.status = .doing
                }
            case .recordMood:
                if let raw = action.mood, let mood = Mood(rawValue: raw) {
                    CheckInService.recordMood(mood, in: context)
                }
            case .addTask:
                await addSharedTask(action, in: context, serverPushActive: serverPushActive)
            case .addNote:
                await addSharedNote(action, in: context)
            }
        }
        try? context.save()
        return actions.count
    }

    /// From the Share extension. The link shows as the task's badge; a PR / ticket code in the
    /// title lets the server link it for real.
    private static func addSharedTask(_ action: WidgetAction, in context: ModelContext, serverPushActive: Bool) async {
        let title = action.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return }
        let task = TaskItem(title: title, category: nil, plannedAt: nil, durationMinutes: nil, source: .manual)
        task.createdAt = action.at
        task.linkURL = action.url
        context.insert(task)
        if action.someday == true {
            TaskActions.moveToBacklog(task)
        } else {
            await TaskActions.schedule(task, at: nil, serverPushActive: serverPushActive)
        }
    }

    private static func addSharedNote(_ action: WidgetAction, in context: ModelContext) async {
        let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        let folder = folders.first { $0.id == action.folderId } ?? folders.first { $0.name == "Ghi chú nhanh" }
        let note = Note(folder: folder)
        note.title = action.title ?? ""
        note.body = action.body ?? ""
        note.createdAt = action.at
        context.insert(note)
        let files = (action.photos ?? []).map { AppGroup.shareInboxDirectory.appending(path: $0) }
        let prepared = await Task.detached {
            files.compactMap { url -> ImageStore.Prepared? in
                defer { try? FileManager.default.removeItem(at: url) }
                return (try? Data(contentsOf: url)).flatMap { ImageStore.prepare($0) }
            }
        }.value
        ImageStore.attach(prepared, to: note, in: context)
    }

    // MARK: Snapshot

    static func build(in context: ModelContext, now: Date = Date()) -> WidgetSnapshot {
        let start = DayClock.startOfDay(now)
        let end = DayClock.endOfDay(now)
        let checkInTime = DayClock.at(hour: AppSettings.checkInHour, minute: AppSettings.checkInMinute, on: now)
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        let checkIn = CheckInService.todaysCheckIn(context, now: now)

        // Morning: what was synced or finished today before the check-in (Calendar, GitHub, Jira,
        // Apple modules, ticks).
        let items = (try? context.fetch(FetchDescriptor<ExternalItem>(predicate: #Predicate {
            $0.occurredAt >= start && $0.occurredAt < end
        }))) ?? []
        // Before the check-in time, and not in the future (upcoming calendar events are not "done").
        var morning = items
            .filter { $0.occurredAt < checkInTime && $0.occurredAt <= now && $0.decision != "ignored" }
            .map { WidgetSnapshot.Item(id: "\($0.sourceRaw)|\($0.externalId)", title: $0.title, source: $0.sourceRaw, time: $0.occurredAt, url: $0.url) }
        morning += tasks.compactMap { task in
            guard task.status == .done, let done = task.completedAt, done >= start, done < checkInTime else { return nil }
            return .init(id: task.id.uuidString, title: task.title, source: nil, time: done, url: nil)
        }
        morning.sort { $0.time < $1.time }

        // Same list as "Hôm nay", including an active Focus Filter.
        let today = FocusFilterState.apply(TodayList.tasks(tasks, now: now)).prefix(20).map { task in
            WidgetSnapshot.TaskRow(
                id: task.id,
                title: task.title,
                status: task.statusRaw,
                plannedAt: task.plannedAt,
                durationMinutes: task.durationMinutes,
                source: ExternalSource(linkURL: task.linkURL)?.rawValue,
                reopenedReason: task.reopenedAt != nil && task.status != .done ? task.reopenedReason : nil,
                createdAt: task.createdAt
            )
        }

        var plan: WidgetSnapshot.Plan?
        if let checkIn, let id = checkIn.afternoonTaskIds.last, let task = tasks.first(where: { $0.id == id }) {
            plan = .init(taskId: task.id, title: task.title, sentence: task.ifThenSentence ?? task.title,
                         plannedAt: task.plannedAt, durationMinutes: task.durationMinutes, status: task.statusRaw)
        }

        return WidgetSnapshot(
            generatedAt: now,
            day: start,
            checkInHour: AppSettings.checkInHour,
            checkInMinute: AppSettings.checkInMinute,
            mood: checkIn?.moodRaw,
            checkInAt: checkIn?.mood != nil ? checkIn?.createdAt : nil,
            plan: plan,
            morning: Array(morning.suffix(12)),
            tasks: Array(today),
            week: DayClock.daysOfWeek(now).map { CheckInPlanner.isMeaningful(day: $0, tasks: tasks) },
            folders: folders(in: context),
            privacy: AppSettings.widgetPrivacy.rawValue
        )
    }

    private static func folders(in context: ModelContext) -> [WidgetSnapshot.FolderRow] {
        let notes = ((try? context.fetch(FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? [])
            .filter { !$0.title.isEmpty || !$0.body.isEmpty }
        func rows(_ list: [Note]) -> [WidgetSnapshot.NoteRow] {
            list.prefix(4).map { .init(id: $0.id, title: $0.displayTitle, preview: $0.preview, updatedAt: $0.updatedAt) }
        }
        var result = [WidgetSnapshot.FolderRow(id: WidgetSnapshot.allNotesID, name: "Tất cả ghi chú", notes: rows(notes))]
        let folders = (try? context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        for folder in folders {
            result.append(.init(id: folder.id, name: folder.name, notes: rows(notes.filter { $0.folder?.id == folder.id })))
        }
        return result
    }
}
