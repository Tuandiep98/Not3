import SwiftUI
import UIKit

/// Design tokens taken from the "Thiết kế màn hình app Note & To-do" canvas.
/// Prefer system semantic colors so Dark Mode works; hex values are the light-mode reference.
enum Theme {
    /// Notes yellow — primary buttons, selected chips, completed checkboxes.
    static let accent = Color(hex: 0xFFD60A)
    /// Text/icon accent with enough contrast on light backgrounds (#8A6100), yellow in dark mode.
    static let accentInk = Color(light: 0x8A6100, dark: 0xFFD60A)
    /// Folder icons and empty checkbox rings (#B8860B).
    static let folderIcon = Color(light: 0xB8860B, dark: 0xE0B341)
    /// Category tag on note rows.
    static let tagBackground = Color(light: 0xFFF3C2, dark: 0x4A3A00)
    static let tagInk = Color(light: 0x6B4B00, dark: 0xFFE27A)
    /// Widget header band.
    static let widgetBand = Color(hex: 0xD46100)

    static let groupedBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let secondaryText = Color(.secondaryLabel)
    static let chipOff = Color(.tertiarySystemFill)

    static let cardRadius: CGFloat = 20
    static let minTouch: CGFloat = 44
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}
