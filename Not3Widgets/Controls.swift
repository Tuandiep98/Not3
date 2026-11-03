import AppIntents
import SwiftUI
import WidgetKit

// Control Center / Lock Screen / Action button controls (iOS 18). Compiled into the app too, so
// intents that open the app run their perform() in the app process.

struct NewTaskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.newTaskControl) {
            ControlWidgetButton(action: OpenNewTaskIntent()) {
                Label("Thêm việc", systemImage: "plus.circle")
            }
        }
        .displayName("Thêm việc")
        .description("Mở Not3 để thêm một việc.")
    }
}

struct CheckInControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.checkInControl) {
            ControlWidgetButton(action: OpenCheckInControlIntent()) {
                Label("Check-in", systemImage: "clock")
            }
        }
        .displayName("Check-in")
        .description("Mở sheet check-in.")
    }
}

/// On = the next task is in progress. Tap: Bắt đầu, tap again: Xong (then the next one shows).
struct NextTaskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.nextTaskControl, provider: NextTaskValueProvider()) { value in
            ControlWidgetToggle(isOn: value.isDoing, action: ToggleNextTaskIntent()) {
                Text(value.title ?? "Không còn việc")
            } valueLabel: { isOn in
                Label(isOn ? "Đang làm · chạm khi xong" : "Bắt đầu", systemImage: isOn ? "checkmark.circle" : "play.circle")
            }
        }
        .displayName("Việc tiếp theo")
        .description("Bắt đầu việc tiếp theo; chạm lần nữa khi xong.")
    }
}

struct NextTaskValue: Sendable {
    var title: String?
    var isDoing: Bool

    init(_ snapshot: WidgetSnapshot) {
        title = snapshot.nextTask?.title
        isDoing = snapshot.nextTask?.status == "doing"
    }

    init(title: String?, isDoing: Bool) {
        self.title = title
        self.isDoing = isDoing
    }
}

struct NextTaskValueProvider: ControlValueProvider {
    var previewValue: NextTaskValue { NextTaskValue(title: "Học 20 từ vựng Anki", isDoing: false) }

    func currentValue() async throws -> NextTaskValue {
        NextTaskValue(WidgetSnapshot.load())
    }
}

// MARK: Intents

struct ToggleNextTaskIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Việc tiếp theo"
    static let isDiscoverable = false

    @Parameter(title: "Đang làm") var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        guard let next = WidgetSnapshot.load().nextTask else { return .result() }
        if value, next.status == "todo" {
            _ = try await StartTaskIntent(taskID: next.id).perform()
        } else if !value {
            _ = try await ToggleTaskIntent(taskID: next.id, done: true).perform()
        }
        ControlCenter.shared.reloadControls(ofKind: WidgetKind.nextTaskControl)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct OpenNewTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Thêm việc mới"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        Router.shared.open(DeepLink.newTask)
        #endif
        return .result()
    }
}

struct OpenCheckInControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Mở check-in"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        Router.shared.openCheckIn()
        #endif
        return .result()
    }
}
