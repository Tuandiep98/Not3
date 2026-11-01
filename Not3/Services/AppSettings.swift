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
        ])
    }

    static var checkInHour: Int { UserDefaults.standard.integer(forKey: SettingsKey.checkInHour) }
    static var checkInMinute: Int { UserDefaults.standard.integer(forKey: SettingsKey.checkInMinute) }
    static var localFallback: Bool { UserDefaults.standard.bool(forKey: SettingsKey.localFallback) }
    static var syncNoteContent: Bool { UserDefaults.standard.bool(forKey: SettingsKey.syncNoteContent) }
}
