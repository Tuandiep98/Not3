import AppIntents

/// Siri phrases are English (Siri has no Vietnamese); the English copies live in
/// Resources/en.lproj/AppShortcuts.strings. Titles shown in Shortcuts stay Vietnamese.
struct Not3Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: ["Add a task in \(.applicationName)", "New task in \(.applicationName)"],
            shortTitle: "Thêm việc",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: TodayStatusIntent(),
            phrases: ["What's left today in \(.applicationName)", "What's next in \(.applicationName)"],
            shortTitle: "Còn việc gì",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: StartNextTaskIntent(),
            phrases: ["Start my next task in \(.applicationName)", "Start next task in \(.applicationName)"],
            shortTitle: "Bắt đầu việc tiếp theo",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: CompleteTaskIntent(),
            phrases: ["Complete \(\.$task) in \(.applicationName)", "Mark a task done in \(.applicationName)"],
            shortTitle: "Đánh dấu xong",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: AddNoteIntent(),
            phrases: ["Add a note in \(.applicationName)", "Quick note in \(.applicationName)"],
            shortTitle: "Ghi chú nhanh",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenCheckInIntent(),
            phrases: ["Check in with \(.applicationName)", "Open \(.applicationName) check-in"],
            shortTitle: "Check-in",
            systemImageName: "clock"
        )
    }
}
