import SwiftUI

/// Icon for where an item comes from: the official GitHub / Jira marks (Simple Icons, CC0 vectors
/// in Assets.xcassets/Brand, tinted with the brand colour), SF Symbol for the iOS Calendar.
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
            case .calendar:
                Image(systemName: "calendar").resizable().scaledToFit()
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
        }
    }
}

/// iOS Settings-style icon: brand-colour rounded tile with a white mark (29 pt like system rows).
struct SourceTile: View {
    let source: ExternalSource
    var size: CGFloat = 29

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(source.tileColor)
            .frame(width: size, height: size)
            .overlay {
                Group {
                    switch source {
                    case .github: Image("logo-github").resizable().scaledToFit()
                    case .jira: Image("logo-jira").resizable().scaledToFit()
                    case .calendar: Image(systemName: "calendar").resizable().scaledToFit().fontWeight(.semibold)
                    }
                }
                .foregroundStyle(.white)
                .padding(size * 0.2)
            }
            .accessibilityHidden(true)
    }
}

extension ExternalSource {
    /// Tile backgrounds; GitHub stays near-black in dark mode but lifts off the background.
    var tileColor: Color {
        switch self {
        case .github: Color(light: 0x181717, dark: 0x3A3A3C)
        case .jira: Color(hex: 0x0052CC)
        case .calendar: Color(hex: 0xFF3B30)
        }
    }
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
