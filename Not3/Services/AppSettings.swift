import Foundation

/// UserDefaults keys shared by @AppStorage and services.
enum SettingsKey {
    static let checkInHour = "checkInHour"
    static let checkInMinute = "checkInMinute"
    static let localFallback = "localFallbackNotifications"
    static let iCloudSync = "iCloudSync"
    static let syncNoteContent = "syncNoteContent"
    static let aiReadsIntegrations = "aiReadsIntegrations"
    static let addToCalendar = "addToCalendar"
    static let eveningCheckIn = "eveningCheckIn"
    static let appLock = "appLock"
    static let appLockDelay = "appLockDelaySeconds"
    // "Hiển thị khi khoá". Unset = follow the Face ID switch (see AppSettings).
    static let widgetPrivacy = "privacyWidgets"
    static let spotlightPrivacy = "privacySpotlight"
    static let siriRequiresUnlock = "privacySiriRequiresUnlock"
    static let obscureSwitcher = "privacyObscureSwitcher"
}

/// What widgets / complications show on a locked device.
enum WidgetPrivacy: String, CaseIterable, Identifiable, Sendable {
    case full, content, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: "Hiện đầy đủ"
        case .content: "Ẩn nội dung"
        case .all: "Ẩn toàn bộ"
        }
    }
}

enum SpotlightPrivacy: String, CaseIterable, Identifiable, Sendable {
    case full, titles, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: "Đầy đủ"
        case .titles: "Chỉ tiêu đề"
        case .hidden: "Không hiện"
        }
    }
}

enum AppSettings {
    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.checkInHour: 12,
            SettingsKey.checkInMinute: 0,
            SettingsKey.localFallback: true,
            SettingsKey.iCloudSync: true,
            SettingsKey.syncNoteContent: true,
            SettingsKey.aiReadsIntegrations: true,
            SettingsKey.addToCalendar: true,
            SettingsKey.eveningCheckIn: true,
            SettingsKey.appLock: false,
            SettingsKey.appLockDelay: 60,
        ])
    }

    static var checkInHour: Int { UserDefaults.standard.integer(forKey: SettingsKey.checkInHour) }
    static var checkInMinute: Int { UserDefaults.standard.integer(forKey: SettingsKey.checkInMinute) }
    static var localFallback: Bool { UserDefaults.standard.bool(forKey: SettingsKey.localFallback) }
    static var syncNoteContent: Bool { UserDefaults.standard.bool(forKey: SettingsKey.syncNoteContent) }
    static var appLockEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.appLock) }
    static var appLockDelay: Int { UserDefaults.standard.integer(forKey: SettingsKey.appLockDelay) }

    // "Hiển thị khi khoá": a value the user picked wins; otherwise the default follows Face ID
    // (stricter when the app lock is on), so toggling Face ID never overwrites a choice.

    static var widgetPrivacy: WidgetPrivacy {
        UserDefaults.standard.string(forKey: SettingsKey.widgetPrivacy).flatMap(WidgetPrivacy.init(rawValue:))
            ?? (appLockEnabled ? .content : .full)
    }

    static var spotlightPrivacy: SpotlightPrivacy {
        UserDefaults.standard.string(forKey: SettingsKey.spotlightPrivacy).flatMap(SpotlightPrivacy.init(rawValue:))
            ?? (appLockEnabled ? .titles : .full)
    }

    static var siriRequiresUnlock: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.siriRequiresUnlock) as? Bool ?? appLockEnabled
    }

    static var obscureSwitcher: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.obscureSwitcher) as? Bool ?? true
    }

    static let privacyKeys = [SettingsKey.widgetPrivacy, SettingsKey.spotlightPrivacy,
                              SettingsKey.siriRequiresUnlock, SettingsKey.obscureSwitcher]

    /// "Khôi phục mặc định": back to following the Face ID switch.
    static func resetPrivacy() {
        privacyKeys.forEach(UserDefaults.standard.removeObject(forKey:))
    }
}
