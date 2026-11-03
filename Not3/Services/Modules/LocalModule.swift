import Foundation
import SwiftData

/// On-device Apple modules — Lời nhắc, Sức khỏe, Gợi ý nhật ký. Like a third-party connection,
/// each stays off until the user turns it on in Settings and grants its own permission; nothing is
/// read before that. What they read stays on this iPhone (never uploaded to Supabase or AI).
@MainActor
enum LocalModule {
    static let all: [ExternalSource] = [.reminders, .health, .journal]

    /// @AppStorage key of the on / off switch.
    nonisolated static func enabledKey(_ source: ExternalSource) -> String { "module.\(source.rawValue).enabled" }

    static func isEnabled(_ source: ExternalSource) -> Bool {
        UserDefaults.standard.bool(forKey: enabledKey(source))
    }

    static func setEnabled(_ source: ExternalSource, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey(source))
    }

    // MARK: Options (`IntegrationOption.reminders` / `.health`)

    private static func optionsKey(_ source: ExternalSource) -> String { "module.\(source.rawValue).options" }

    static func options(_ source: ExternalSource) -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: optionsKey(source)) as? [String: Bool] ?? [:]
    }

    static func setOptions(_ source: ExternalSource, _ options: [String: Bool]) {
        UserDefaults.standard.set(options, forKey: optionsKey(source))
    }

    /// Stored value, else the option's default.
    static func isOn(_ key: String, for source: ExternalSource) -> Bool {
        guard let option = IntegrationOption.options(for: source).first(where: { $0.key == key }) else { return false }
        return IntegrationOption.value(option, in: options(source))
    }

    // MARK: Lists / calendars left out (Lịch, Lời nhắc)

    private static func excludedKey(_ source: ExternalSource) -> String { "module.\(source.rawValue).excluded" }

    static func excluded(_ source: ExternalSource) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: excludedKey(source)) ?? [])
    }

    static func setExcluded(_ source: ExternalSource, _ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: excludedKey(source))
    }

    // MARK: Turning off

    /// "Tắt": forgets what was read. Tasks already made from reminders stay (they are the user's now).
    static func disable(_ source: ExternalSource, in context: ModelContext) {
        setEnabled(source, false)
        let raw = source.rawValue
        try? context.delete(model: ExternalItem.self, where: #Predicate { $0.sourceRaw == raw })
        try? context.save()
        JournalService.updateToday(in: context)
        WidgetBridge.publishSoon()
    }

    /// Re-reads every module that is on. Called with the Calendar pass (foreground, background refresh).
    static func refreshAll(in context: ModelContext) async {
        await RemindersService.shared.refresh(in: context)
        await HealthService.shared.refresh(in: context)
    }
}
