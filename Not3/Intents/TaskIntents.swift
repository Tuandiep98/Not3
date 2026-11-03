import AppIntents
import Foundation
import SwiftData

// Shortcuts / Siri / Action button. They run in the app process without opening the UI
// (except check-in and notes), using the same TaskActions as the app.

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Thêm việc"
    static let description = IntentDescription("Thêm một việc vào Hôm nay, lúc một giờ cụ thể, hoặc vào Hộp chờ.")

    @Parameter(title: "Việc", requestValueDialog: "Việc gì?")
    var title: String

    @Parameter(title: "Lúc")
    var date: Date?

    @Parameter(title: "Thời lượng (phút)")
    var minutes: Int?

    @Parameter(title: "Để vào hộp chờ", default: false)
    var someday: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Thêm \(\.$title)") {
            \.$date
            \.$minutes
            \.$someday
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<TaskEntity> {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw $title.needsValueError("Việc gì?") }
        let context = Persistence.shared.mainContext
        let task = TaskItem(title: text, category: nil, plannedAt: nil, durationMinutes: minutes, source: .manual)
        context.insert(task)
        if someday {
            TaskActions.moveToBacklog(task)
        } else {
            await TaskActions.schedule(task, at: date, serverPushActive: SupabaseService.shared.hasServerPush)
        }
        try? context.save()
        WidgetBridge.publish()
        let where_ = someday ? "vào Hộp chờ" : date.map { "lúc \(DayClock.time($0))" } ?? "vào Hôm nay"
        return .result(value: TaskEntity(task), dialog: "Đã thêm \"\(text)\" \(where_).")
    }
}

struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Đánh dấu việc xong"
    // Lists task names: not from a locked iPhone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Việc", requestValueDialog: "Việc nào?")
    var task: TaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Xong \(\.$task)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = Persistence.shared.mainContext
        guard let item = TaskActions.task(id: task.id, in: context) else {
            return .result(dialog: "Không tìm thấy việc này.")
        }
        await TaskActions.setDone(item, true, serverPushActive: SupabaseService.shared.hasServerPush)
        try? context.save()
        WidgetBridge.publish()
        return .result(dialog: "Xong: \(item.title). \(TodayStatus.text(TaskEntityQuery.allTasks()))")
    }
}

struct StartNextTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Bắt đầu việc tiếp theo"
    static let description = IntentDescription("Chuyển việc tiếp theo của hôm nay sang Đang làm.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = Persistence.shared.mainContext
        let all = TaskEntityQuery.allTasks()
        if let doing = TodayList.tasks(all).first(where: { $0.status == .doing }) {
            return .result(dialog: "Bạn đang làm: \(doing.title).")
        }
        guard let next = TodayStatus.next(all) else {
            return .result(dialog: "Không còn việc nào hôm nay.")
        }
        next.status = .doing
        NotificationService.cancelReminder(for: next.id)
        try? context.save()
        WidgetBridge.publish()
        return .result(dialog: "Bắt đầu: \(next.title)\(next.durationMinutes.map { " · \($0) phút" } ?? "").")
    }
}

struct TodayStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Hôm nay còn việc gì"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[TaskEntity]> {
        let all = TaskEntityQuery.allTasks()
        let open = TodayList.tasks(all).filter { $0.status != .done }
        return .result(value: open.map(TaskEntity.init), dialog: "\(TodayStatus.text(all))")
    }
}

struct OpenCheckInIntent: AppIntent {
    static let title: LocalizedStringResource = "Check-in"
    static let description = IntentDescription("Mở sheet check-in của Not3.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.openCheckIn()
        return .result()
    }
}

/// Text answers shared by the intents.
@MainActor
enum TodayStatus {
    /// Next open task of today: earliest planned time, else creation order (the Today list order).
    static func next(_ all: [TaskItem], now: Date = Date()) -> TaskItem? {
        TodayList.tasks(all, now: now).first { $0.status == .todo }
    }

    /// "Còn 3 việc. Tiếp theo: 14:00 Học Anki." / "Đã xong cả 4 việc hôm nay." / "Hôm nay chưa có việc nào."
    static func text(_ all: [TaskItem], now: Date = Date()) -> String {
        let today = TodayList.tasks(all, now: now)
        let open = today.filter { $0.status != .done }
        guard !today.isEmpty else { return "Hôm nay chưa có việc nào." }
        guard !open.isEmpty else { return "Đã xong cả \(today.count) việc hôm nay." }
        let current = open.first { $0.status == .doing } ?? next(all, now: now)
        guard let current else { return "Còn \(open.count) việc." }
        let time = current.plannedAt.map { "\(DayClock.time($0)) " } ?? ""
        let label = current.status == .doing ? "Đang làm" : "Tiếp theo"
        return "Còn \(open.count) việc. \(label): \(time)\(current.title)."
    }
}
