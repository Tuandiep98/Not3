import LocalAuthentication
import SwiftUI
import UIKit

/// "Khoá bằng Face ID": a cover over every window (sheets included) after the app has been in the
/// background for the chosen delay; also hides content in the app switcher.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    enum Delay: Int, CaseIterable, Identifiable {
        case immediately = 0, oneMinute = 60, fiveMinutes = 300
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .immediately: "Ngay lập tức"
            case .oneMinute: "Sau 1 phút"
            case .fiveMinutes: "Sau 5 phút"
            }
        }
    }

    private(set) var isLocked = AppSettings.appLockEnabled
    private var isObscured = false
    private var backgroundedAt: Date?
    private var isAuthenticating = false
    private var windows: [UIWindow] = []

    /// "Face ID", "Touch ID" or "mật mã", for labels.
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "mật mã"
        }
    }

    // MARK: Scene phases

    func didEnterBackground() {
        guard AppSettings.appLockEnabled else { return }
        if backgroundedAt == nil { backgroundedAt = Date() }
        isObscured = AppSettings.obscureSwitcher
        updateCover()
    }

    func willResignActive() {
        guard AppSettings.appLockEnabled, AppSettings.obscureSwitcher else { return }
        isObscured = true
        updateCover()
    }

    func didBecomeActive() {
        guard AppSettings.appLockEnabled else {
            isLocked = false
            isObscured = false
            updateCover()
            return
        }
        // The Face ID prompt itself makes the app inactive: that must not lock again.
        if !isAuthenticating, let at = backgroundedAt, Date().timeIntervalSince(at) >= Double(AppSettings.appLockDelay) {
            isLocked = true
        }
        backgroundedAt = nil
        isObscured = false
        updateCover()
        if isLocked { Task { await unlock() } }
    }

    // MARK: Unlock

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        let ok = await Self.authenticate(reason: "Mở khoá Not3")
        isAuthenticating = false
        if ok {
            isLocked = false
            updateCover()
        }
    }

    /// Face ID / Touch ID, falling back to the device passcode.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on the device: nothing to check against.
            return true
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Settings switch: confirm with Face ID before turning the lock on or off.
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard await Self.authenticate(reason: enabled ? "Bật khoá Not3" : "Tắt khoá Not3") else { return false }
        UserDefaults.standard.set(enabled, forKey: SettingsKey.appLock)
        isLocked = false
        updateCover()
        WidgetBridge.publish()
        SpotlightIndexer.update()
        return true
    }

    // MARK: Cover

    /// A window above everything else in each scene, so open sheets are covered too.
    private func updateCover() {
        let show = AppSettings.appLockEnabled && (isLocked || isObscured)
        guard show else {
            windows.forEach { $0.isHidden = true }
            windows = []
            return
        }
        guard windows.isEmpty else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: LockView(lock: self))
            window.rootViewController?.view.backgroundColor = .clear
            window.isHidden = false
            windows.append(window)
        }
    }
}

private struct LockView: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.accentInk)
                Text("Not3 đang khoá").font(.title3.weight(.semibold))
                if lock.isLocked {
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Text("Mở bằng \(AppLock.biometryName)").font(.headline).frame(maxWidth: 260)
                    }
                    .appPrimaryButton()
                }
            }
            .padding(24)
        }
    }
}
