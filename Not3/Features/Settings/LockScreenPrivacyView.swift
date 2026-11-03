import SwiftUI
import UIKit

/// "Hiển thị khi khoá": what widgets, Spotlight and Siri show while the iPhone is locked.
/// Defaults follow the Face ID switch until the user picks a value here.
struct LockScreenPrivacyView: View {
    @Environment(\.openURL) private var openURL

    @State private var widgets = AppSettings.widgetPrivacy
    @State private var spotlight = AppSettings.spotlightPrivacy
    @State private var siriRequiresUnlock = AppSettings.siriRequiresUnlock
    @State private var obscureSwitcher = AppSettings.obscureSwitcher
    @State private var isCustomized = Self.hasCustomValues

    private let appLock = AppSettings.appLockEnabled

    var body: some View {
        Form {
            Section {
                Picker("Widget & complication", selection: stored($widgets, SettingsKey.widgetPrivacy)) {
                    ForEach(WidgetPrivacy.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text(widgetsFooter)
            }

            Section {
                Picker("Spotlight", selection: stored($spotlight, SettingsKey.spotlightPrivacy)) {
                    ForEach(SpotlightPrivacy.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text(spotlightFooter)
            }

            Section {
                Toggle("Siri & Phím tắt cần mở khoá", isOn: stored($siriRequiresUnlock, SettingsKey.siriRequiresUnlock))
            } footer: {
                Text("Khi iPhone đang khoá, \"Hôm nay còn việc gì\" và \"Đánh dấu xong\" sẽ nhắc mở khoá; \"Bắt đầu việc tiếp theo\" vẫn chạy nhưng không đọc tên việc. Thêm việc, ghi chú nhanh luôn dùng được.")
            }

            Section {
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                } label: {
                    LabeledContent("Thông báo") {
                        Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            } footer: {
                Text("Chọn \"Hiển thị bản xem trước: Khi được mở khoá\" trong cài đặt iOS để ẩn tên việc trên thông báo khi máy khoá.")
            }

            if appLock {
                Section {
                    Toggle("Che app khi chuyển app", isOn: stored($obscureSwitcher, SettingsKey.obscureSwitcher))
                } footer: {
                    Text("Màn hình đa nhiệm chỉ hiện ổ khoá thay vì nội dung Not3.")
                }
            }

            if isCustomized {
                Section {
                    Button("Khôi phục mặc định") { reset() }
                } footer: {
                    Text("Mặc định đi theo \"Khoá bằng \(AppLock.biometryName)\": tắt thì hiện đầy đủ, bật thì ẩn nội dung.")
                }
            }
        }
        .navigationTitle("Hiển thị khi khoá")
    }

    private var widgetsFooter: String {
        switch widgets {
        case .full: "Widget trên màn hình khoá, Today, StandBy và mặt đồng hồ hiện đủ tên việc, ghi chú."
        case .content: "Khi máy khoá: che tên việc, ghi chú và câu nếu–thì; vẫn thấy tiêu đề widget, số việc xong và vòng tuần."
        case .all: "Khi máy khoá: che cả widget. Mở khoá xong (Home Screen) vẫn hiện bình thường."
        }
    }

    private var spotlightFooter: String {
        switch spotlight {
        case .full: "Tìm được theo tiêu đề và nội dung ghi chú, việc."
        case .titles: "Kết quả chỉ hiện tiêu đề; nội dung không được đưa vào Spotlight."
        case .hidden: "Không đưa ghi chú hay việc nào vào Spotlight."
        }
    }

    private static var hasCustomValues: Bool {
        AppSettings.privacyKeys.contains { UserDefaults.standard.object(forKey: $0) != nil }
    }

    /// Only what the user changes is stored, so untouched settings keep following Face ID.
    private func stored<T: RawRepresentable>(_ state: Binding<T>, _ key: String) -> Binding<T> {
        Binding(get: { state.wrappedValue }, set: { value in
            state.wrappedValue = value
            UserDefaults.standard.set(value.rawValue, forKey: key)
            isCustomized = true
            apply()
        })
    }

    private func stored(_ state: Binding<Bool>, _ key: String) -> Binding<Bool> {
        Binding(get: { state.wrappedValue }, set: { value in
            state.wrappedValue = value
            UserDefaults.standard.set(value, forKey: key)
            isCustomized = true
            apply()
        })
    }

    private func reset() {
        AppSettings.resetPrivacy()
        widgets = AppSettings.widgetPrivacy
        spotlight = AppSettings.spotlightPrivacy
        siriRequiresUnlock = AppSettings.siriRequiresUnlock
        obscureSwitcher = AppSettings.obscureSwitcher
        isCustomized = false
        apply()
    }

    private func apply() {
        WidgetBridge.publish()
        SpotlightIndexer.update()
    }
}
