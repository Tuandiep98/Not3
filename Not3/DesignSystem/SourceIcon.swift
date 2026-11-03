import SwiftUI

/// Icon for where an item comes from: the official GitHub / Jira marks (Simple Icons, CC0 vectors
/// in Assets.xcassets/Brand, tinted with the brand colour), SF Symbols in the colour of Apple's own
/// app for Lịch, Lời nhắc, Sức khỏe and Gợi ý nhật ký.
struct SourceIcon: View {
    let source: ExternalSource
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch source {
            case .github:
                Image("logo-github").resizable().scaledToFit()
            case .jira:
                Image("logo-jira").resizable().scaledToFit()
            default:
                Image(systemName: source.systemImage).resizable().scaledToFit()
            }
        }
        .foregroundStyle(source.brandColor)
        .frame(width: size, height: size)
        .accessibilityLabel(source.label)
    }
}

extension ExternalSource {
    /// GitHub: black (white in dark mode); Jira: Atlassian blue #0052CC (lighter in dark mode).
    var brandColor: Color {
        switch self {
        case .github: Color(light: 0x181717, dark: 0xF0F0F0)
        case .jira: Color(light: 0x0052CC, dark: 0x579DFF)
        case .calendar: Color(light: 0xE5383B, dark: 0xFF6B6E)
        case .reminders: Color(light: 0x007AFF, dark: 0x0A84FF)
        case .health: Color(light: 0xFF2D55, dark: 0xFF375F)
        case .journal: Color(light: 0x8E6CEF, dark: 0xA88BFF)
        }
    }
}

/// iOS Settings-style icon (29 pt like system rows). GitHub / Jira: brand-colour tile with a white
/// mark. Apple apps: drawn like their home-screen icon — white tile (dark in Dark Mode) for Lịch,
/// Lời nhắc and Sức khỏe, the Journal gradient for Gợi ý nhật ký.
struct SourceTile: View {
    let source: ExternalSource
    var size: CGFloat = 29

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(source.tileFill)
            .frame(width: size, height: size)
            .overlay { mark }
            .overlay {
                // White tiles need an edge on a white row.
                if source.hasLightTile {
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch source {
        case .github, .jira:
            Image(source == .github ? "logo-github" : "logo-jira")
                .resizable().scaledToFit()
                .foregroundStyle(.white)
                .padding(size * 0.2)
        case .calendar:
            CalendarMark(size: size)
        case .reminders:
            RemindersMark(size: size)
        case .health:
            Image(systemName: "heart.fill")
                .resizable().scaledToFit()
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFF6482), Color(hex: 0xFF2D55)],
                                                startPoint: .top, endPoint: .bottom))
                .padding(size * 0.2)
        case .journal:
            Image(systemName: "book.closed.fill")
                .resizable().scaledToFit()
                .foregroundStyle(.white)
                .padding(size * 0.24)
        }
    }
}

/// Calendar app icon: today's weekday in red over the day number.
private struct CalendarMark: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: -size * 0.04) {
                Text(context.date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "vi_VN"))))
                    .font(.system(size: size * 0.2, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFF3B30))
                Text(context.date.formatted(.dateTime.day()))
                    .font(.system(size: size * 0.5, weight: .regular))
                    .foregroundStyle(Color(light: 0x000000, dark: 0xFFFFFF))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, size * 0.08)
        }
    }
}

/// Reminders app icon: three coloured rings, each with a grey line.
private struct RemindersMark: View {
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.09) {
            ForEach([0x007AFF, 0xFF3B30, 0xFF9500] as [UInt32], id: \.self) { hex in
                HStack(spacing: size * 0.07) {
                    Circle()
                        .strokeBorder(Color(hex: hex), lineWidth: size * 0.035)
                        .background(Circle().fill(Color(hex: hex)).padding(size * 0.035))
                        .frame(width: size * 0.17, height: size * 0.17)
                    Capsule()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: size * 0.4, height: size * 0.035)
                }
            }
        }
    }
}

extension ExternalSource {
    /// Tile backgrounds; GitHub stays near-black in dark mode but lifts off the background.
    var tileFill: AnyShapeStyle {
        switch self {
        case .github: AnyShapeStyle(Color(light: 0x181717, dark: 0x3A3A3C))
        case .jira: AnyShapeStyle(Color(hex: 0x0052CC))
        case .calendar, .reminders, .health: AnyShapeStyle(Color(light: 0xFFFFFF, dark: 0x2C2C2E))
        case .journal: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x8E6CEF), Color(hex: 0xF0709F), Color(hex: 0xFFB35C)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    var hasLightTile: Bool { self == .calendar || self == .reminders || self == .health }
}

/// One row of "Dữ liệu đã kết nối": tile · title / one-line subtitle · trailing accessory.
struct ConnectionRow<Accessory: View>: View {
    let source: ExternalSource
    let title: String
    let subtitle: String
    var subtitleIsWarning = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            SourceTile(source: source)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                HStack(spacing: 4) {
                    if subtitleIsWarning {
                        Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
                    }
                    Text(subtitle).lineLimit(1).truncationMode(.tail)
                }
                .font(.footnote)
                .foregroundStyle(subtitleIsWarning ? Color.orange : Color.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            accessory
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
