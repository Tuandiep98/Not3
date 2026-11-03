import XCTest
@testable import Not3

final class PrivacySettingsTests: XCTestCase {
    private let keys = AppSettings.privacyKeys + [SettingsKey.appLock]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        AppSettings.register()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testDefaultsFollowFaceID() {
        XCTAssertEqual(AppSettings.widgetPrivacy, .full)
        XCTAssertEqual(AppSettings.spotlightPrivacy, .full)
        XCTAssertFalse(AppSettings.siriRequiresUnlock)
        XCTAssertTrue(AppSettings.obscureSwitcher)

        UserDefaults.standard.set(true, forKey: SettingsKey.appLock)
        XCTAssertEqual(AppSettings.widgetPrivacy, .content)
        XCTAssertEqual(AppSettings.spotlightPrivacy, .titles)
        XCTAssertTrue(AppSettings.siriRequiresUnlock)
    }

    func testUserChoiceIsKeptWhenFaceIDChanges() {
        UserDefaults.standard.set(WidgetPrivacy.all.rawValue, forKey: SettingsKey.widgetPrivacy)
        UserDefaults.standard.set(false, forKey: SettingsKey.siriRequiresUnlock)
        UserDefaults.standard.set(true, forKey: SettingsKey.appLock)
        XCTAssertEqual(AppSettings.widgetPrivacy, .all)
        XCTAssertFalse(AppSettings.siriRequiresUnlock)
        XCTAssertEqual(AppSettings.spotlightPrivacy, .titles, "untouched setting still follows Face ID")

        AppSettings.resetPrivacy()
        XCTAssertEqual(AppSettings.widgetPrivacy, .content)
        XCTAssertTrue(AppSettings.siriRequiresUnlock)
    }

    func testSnapshotLevels() {
        var snapshot = WidgetSnapshot.empty
        XCTAssertFalse(snapshot.hidesContent)
        snapshot.privacy = "content"
        XCTAssertTrue(snapshot.hidesContent)
        XCTAssertFalse(snapshot.hidesAll)
        snapshot.privacy = "all"
        XCTAssertTrue(snapshot.hidesContent)
        XCTAssertTrue(snapshot.hidesAll)
    }
}
