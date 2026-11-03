import EventKit
import Foundation
import Observation
import SwiftData

/// iOS Calendar, on device only (Apple has no server API for EventKit — README §11).
/// - Reads today's events → `ExternalItem(source: .calendar)` → morning chips, then uploads them.
/// - Writes afternoon plans into the app's own calendar "Not3".
/// - Two-way: moving / deleting that event in Calendar updates the task.
@MainActor
@Observable
final class CalendarService {
    static let shared = CalendarService()

    private let store = EKEventStore()
    private(set) var isAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    private var observer: NSObjectProtocol?
    private static let calendarIdKey = "appCalendarIdentifier"
    private static let calendarTitle = "Not3"

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    /// Full access is needed for both reading the morning and syncing edits back.
    @discardableResult
    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        isAuthorized = granted
        if granted { startObserving() }
        return granted
    }

    func startObserving() {
        guard isAuthorized, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { _ in
            Task { @MainActor in
                let context = Persistence.shared.mainContext
                await CalendarService.shared.refresh(in: context)
            }
        }
    }

    /// Import today + reconcile plan events. Called on foreground, on calendar changes and when
    /// the check-in sheet opens (background refresh is not guaranteed to run on time).
    func refresh(in context: ModelContext) async {
        guard isAuthorized else { return }
        importToday(in: context)
        await reconcile(in: context)
        try? context.save()
    }

    // MARK: Read today

    func importToday(in context: ModelContext, now: Date = Date()) {
        guard isAuthorized else { return }
        let start = DayClock.startOfDay(now)
        let end = DayClock.endOfDay(now)
        let calendars = readableCalendars()
        guard !calendars.isEmpty else { return }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .filter { !$0.isAllDay && $0.status != .canceled }

        let raw = ExternalSource.calendar.rawValue
        let existing = (try? context.fetch(FetchDescriptor<ExternalItem>(predicate: #Predicate {
            $0.sourceRaw == raw && $0.occurredAt >= start && $0.occurredAt < end
        }))) ?? []
        var byId = Dictionary(existing.map { ($0.externalId, $0) }, uniquingKeysWith: { first, _ in first })

        for event in events {
            let id = Self.externalId(for: event)
            let title = "\(event.title ?? "Sự kiện") \(DayClock.time(event.startDate))"
            if let item = byId.removeValue(forKey: id) {
                item.title = title
                item.occurredAt = event.startDate
            } else {
                context.insert(ExternalItem(source: .calendar, externalId: id, title: title, url: nil, occurredAt: event.startDate))
            }
        }
        // Events deleted from Calendar disappear from today's morning.
        byId.values.forEach(context.delete)
    }

    /// Meetings with their real start and end, for "Tổng kết tuần". Skips all-day, cancelled and
    /// declined events, and Not3's own plan calendar (those are tasks, counted separately).
    func meetings(from start: Date, to end: Date) -> [ActivityInput] {
        guard isAuthorized else { return [] }
        let calendars = readableCalendars()
        guard !calendars.isEmpty else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .filter { event in
                !event.isAllDay && event.status != .canceled
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
                    && event.endDate > event.startDate
            }
            .map {
                ActivityInput(start: $0.startDate, end: $0.endDate, kind: .meeting,
                              title: $0.title ?? "Sự kiện", precision: .measured, source: .calendar)
            }
    }

    /// Calendars offered in Settings → Lịch (Not3's own plan calendar is never read back).
    func calendars() -> [EKCalendar] {
        guard isAuthorized else { return [] }
        let ownId = UserDefaults.standard.string(forKey: Self.calendarIdKey)
        return store.calendars(for: .event)
            .filter { $0.calendarIdentifier != ownId }
            .sorted { ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title) }
    }

    /// Calendars the user left on in Settings → Lịch.
    private func readableCalendars() -> [EKCalendar] {
        let excluded = LocalModule.excluded(.calendar)
        return calendars().filter { !excluded.contains($0.calendarIdentifier) }
    }

    private static func externalId(for event: EKEvent) -> String {
        let base = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString
        return "\(base)@\(Int(event.startDate.timeIntervalSince1970))"
    }

    // MARK: Write plans

    /// The app's own calendar, created on first use in the default event source.
    private func appCalendar() throws -> EKCalendar {
        if let id = UserDefaults.standard.string(forKey: Self.calendarIdKey),
           let calendar = store.calendar(withIdentifier: id) {
            return calendar
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.calendarTitle
        calendar.cgColor = CGColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)
        calendar.source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .calDAV || $0.sourceType == .local }
        try store.saveCalendar(calendar, commit: true)
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: Self.calendarIdKey)
        return calendar
    }

    private func event(for task: TaskItem) -> EKEvent? {
        guard let id = task.calendarEventId else { return nil }
        return store.calendarItems(withExternalIdentifier: id).compactMap { $0 as? EKEvent }.first
    }

    /// Creates or updates the event for a planned task. Title comes from the app (source of truth).
    func writePlan(_ task: TaskItem) {
        guard isAuthorized, let start = task.plannedAt else { return }
        do {
            let event = event(for: task) ?? EKEvent(eventStore: store)
            if event.calendar == nil { event.calendar = try appCalendar() }
            event.title = task.title
            event.startDate = start
            event.endDate = start.addingTimeInterval(Double(task.durationMinutes ?? 30) * 60)
            event.notes = task.ifThenSentence
            try store.save(event, span: .thisEvent, commit: true)
            task.calendarEventId = event.calendarItemExternalIdentifier
        } catch {
            // Calendar is optional: the plan, reminder and push still work without it.
        }
    }

    func removePlan(_ task: TaskItem) {
        guard isAuthorized, let event = event(for: task) else { return }
        try? store.remove(event, span: .thisEvent, commit: true)
        task.calendarEventId = nil
    }

    // MARK: Calendar → app

    /// Moved event → move the task (and its reminders). Deleted event → task cancelled.
    /// Event time passed → nothing; the evening check asks "Đã làm chưa?".
    func reconcile(in context: ModelContext) async {
        guard isAuthorized else { return }
        let todo = TaskStatus.todo.rawValue
        let linked = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.calendarEventId != nil && $0.statusRaw == todo
        }))) ?? []
        let serverPush = SupabaseService.shared.hasServerPush
        for task in linked {
            guard let event = event(for: task) else {
                task.status = .cancelled
                task.calendarEventId = nil
                NotificationService.cancelReminder(for: task.id)
                continue
            }
            let minutes = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
            if task.plannedAt != event.startDate || task.durationMinutes != minutes {
                task.plannedAt = event.startDate
                task.durationMinutes = minutes
                task.touch()
                await NotificationService.scheduleTaskNotifications(for: task, serverPushActive: serverPush)
            }
        }
    }
}
