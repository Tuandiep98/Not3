import SwiftUI
import WidgetKit

/// Notes-style widget card from the design: coloured header band (#D46100), white body,
/// soft orange chips. In tinted / clear modes (iOS 18 / 26) the band drops its fill and the
/// hierarchy comes from type weight, as the design notes.
enum WStyle {
    static let band = Color(light: 0xD46100, dark: 0xC45500)
    static let chipFill = Color(light: 0xFFF1E3, dark: 0x4A2A10)
    static let chipText = Color(light: 0x9A4300, dark: 0xFFB37A)
    static let ring = Color(light: 0xC45500, dark: 0xFF9F55)
    static let separator = Color(.separator)
}

#if WIDGET_EXTENSION
// The app target already defines these (DesignSystem/Theme.swift).
extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }
}
#endif

// MARK: Privacy

extension EnvironmentValues {
    /// "Hiển thị khi khoá" = hide content: set from the snapshot at each widget's root.
    @Entry var hidesPrivateContent = false
}

private struct PrivateContent: ViewModifier {
    @Environment(\.hidesPrivateContent) private var hides

    func body(content: Content) -> some View {
        content.privacySensitive(hides)
    }
}

extension View {
    /// Task / note titles and other personal text: redacted on a locked device when the user
    /// chose "Ẩn nội dung" (headers and counts stay readable).
    func privateContent() -> some View {
        modifier(PrivateContent())
    }
}

/// Coloured header band with a title (and optional trailing text / view).
struct WidgetHeader<Trailing: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var trailing: Trailing
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.subheadline.weight(.semibold)) }
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            trailing.font(.caption.weight(.semibold))
        }
        .foregroundStyle(mode == .fullColor ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(mode == .fullColor ? WStyle.band : Color.primary.opacity(0.08))
        .widgetAccentable()
    }
}

extension WidgetHeader where Trailing == EmptyView {
    init(title: String, systemImage: String? = nil) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

/// GitHub / Jira mark (vector assets shared with the app), SF Symbol for Calendar.
struct SourceMark: View {
    let source: String?
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch source {
            case "github": Image("logo-github").resizable().scaledToFit().foregroundStyle(.primary)
            case "jira": Image("logo-jira").resizable().scaledToFit().foregroundStyle(Color(light: 0x0052CC, dark: 0x579DFF))
            case "calendar": Image(systemName: "calendar").resizable().scaledToFit().foregroundStyle(.red)
            default: Image(systemName: "checkmark.circle").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum WFormat {
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func detail(_ task: WidgetSnapshot.TaskRow, now: Date = Date()) -> String {
        var parts: [String] = []
        if let planned = task.plannedAt {
            parts.append(Calendar.current.isDate(planned, inSameDayAs: now)
                ? time(planned)
                : planned.formatted(.dateTime.day().month(.defaultDigits)) + " " + time(planned))
        }
        if let minutes = task.durationMinutes { parts.append("\(minutes)p") }
        if task.status == "doing" { parts.append("Đang làm") }
        return parts.joined(separator: " · ")
    }
}
