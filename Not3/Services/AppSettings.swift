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
    /// Check-in duration chips in minutes, as an `IntList` ("15,25,45,60").
    static let checkInDurations = "checkInDurations"
    /// Afternoon time chips in minutes after midnight, as an `IntList` ("840,930,1020").
    static let checkInTimeSlots = "checkInTimeSlots"
    /// "Nếu lỡ giờ thì…" picked last time, offered again at the next check-in (`CopingPlan`, "" = none).
    static let lastCopingPlan = "lastCopingPlan"
    /// "Khép lại hôm nay": on / off and the evening reminder time.
    static let shutdown = "shutdownEnabled"
    static let shutdownHour = "shutdownHour"
    static let shutdownMinute = "shutdownMinute"
    static let appLock = "appLock"
    static let appLockDelay = "appLockDelaySeconds"
    // "Hiển thị khi khoá". Unset = follow the Face ID switch (see AppSettings).
    static let widgetPrivacy = "privacyWidgets"
    static let spotlightPrivacy = "privacySpotlight"
    static let siriRequiresUnlock = "privacySiriRequiresUnlock"
    static let obscureSwitcher = "privacyObscureSwitcher"
}

/// Sorted, de-duplicated ints stored as "15,25,45" so @AppStorage can bind a list.
enum IntList {
    static func decode(_ raw: String) -> [Int] {
        Array(Set(raw.split(separator: ",").compactMap { Int($0) })).sorted()
    }

    static func encode(_ values: [Int]) -> String {
        Array(Set(values)).sorted().map(String.init).joined(separator: ",")
    }
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
            SettingsKey.checkInDurations: IntList.encode(ChipCatalog.defaultDurations),
            SettingsKey.checkInTimeSlots: IntList.encode(ChipCatalog.defaultTimeSlots),
            SettingsKey.lastCopingPlan: CopingPlan.nextGap.rawValue,
            SettingsKey.shutdown: true,
            SettingsKey.shutdownHour: 21,
            SettingsKey.shutdownMinute: 30,
            SettingsKey.appLock: false,
            SettingsKey.appLockDelay: 60,
        ])
    }

    static var checkInHour: Int { UserDefaults.standard.integer(forKey: SettingsKey.checkInHour) }
    static var checkInMinute: Int { UserDefaults.standard.integer(forKey: SettingsKey.checkInMinute) }
    static var localFallback: Bool { UserDefaults.standard.bool(forKey: SettingsKey.localFallback) }
    static var syncNoteContent: Bool { UserDefaults.standard.bool(forKey: SettingsKey.syncNoteContent) }
    static var appLockEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.appLock) }
    static var shutdownEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.shutdown) }

    /// One "Xong chưa?" per planned task — only while "Khép lại hôm nay" is off; when it is on,
    /// that single evening notification covers every open task (also tells the server via profile).
    static var perTaskEveningCheck: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.eveningCheckIn) && !shutdownEnabled
    }

    static func shutdownTime(on day: Date = Date()) -> Date {
        DayClock.at(hour: UserDefaults.standard.integer(forKey: SettingsKey.shutdownHour),
                    minute: UserDefaults.standard.integer(forKey: SettingsKey.shutdownMinute), on: day)
    }
    static var appLockDelay: Int { UserDefaults.standard.integer(forKey: SettingsKey.appLockDelay) }

    static var checkInDurations: [Int] {
        UserDefaults.standard.string(forKey: SettingsKey.checkInDurations).map(IntList.decode)
            ?? ChipCatalog.defaultDurations
    }

    static var checkInTimeSlots: [Int] {
        UserDefaults.standard.string(forKey: SettingsKey.checkInTimeSlots).map(IntList.decode)
            ?? ChipCatalog.defaultTimeSlots
    }

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
