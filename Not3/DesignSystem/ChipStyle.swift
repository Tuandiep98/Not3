import SwiftUI

/// Colours a category can take (system colours, so they adapt to dark mode and Increase Contrast).
enum ChipColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    var label: String {
        switch self {
        case .red: "Đỏ"
        case .orange: "Cam"
        case .yellow: "Vàng"
        case .green: "Xanh lá"
        case .mint: "Bạc hà"
        case .teal: "Xanh mòng két"
        case .blue: "Xanh dương"
        case .indigo: "Chàm"
        case .purple: "Tím"
        case .pink: "Hồng"
        case .brown: "Nâu"
        case .gray: "Xám"
        }
    }
}

extension Chip {
    var chipColor: ChipColor? { colorName.flatMap(ChipColor.init(rawValue:)) }
}

extension ChipButton {
    /// A category / feeling chip with its own symbol and colour.
    init(chip: Chip, isOn: Bool, action: @escaping () -> Void) {
        self.init(title: chip.label, isOn: isOn, systemImage: chip.symbol, tint: chip.chipColor?.color, action: action)
    }
}

/// SF Symbols offered in the chip editor.
enum ChipSymbols {
    static let category = [
        "tag.fill", "briefcase.fill", "laptopcomputer", "book.fill", "graduationcap.fill", "character.book.closed.fill",
        "heart.fill", "figure.walk", "dumbbell.fill", "leaf.fill", "fork.knife", "cup.and.saucer.fill",
        "paintbrush.fill", "music.note", "gamecontroller.fill", "camera.fill", "house.fill", "cart.fill",
        "person.2.fill", "star.fill", "lightbulb.fill", "wrench.and.screwdriver.fill", "airplane", "dollarsign.circle.fill",
    ]

    static let mood = [
        "sun.max.fill", "cloud.sun.fill", "moon.zzz.fill", "bolt.fill", "flame.fill", "sparkles",
        "face.smiling", "hand.thumbsup.fill", "target", "brain.head.profile", "battery.100.bolt", "zzz",
        "cloud.rain.fill", "tornado", "tortoise.fill", "hare.fill", "cup.and.saucer.fill", "bed.double.fill",
    ]
}

/// Category colour + symbol by name, mirrored to UserDefaults by `ChipStore` so views without a
/// model context (weekly summary styles, task rows) can read them.
enum CategoryAppearance {
    struct Style: Equatable, Sendable {
        var color: ChipColor?
        var symbol: String?
    }

    private static let key = "categoryAppearance"

    static func style(for name: String?) -> Style? {
        guard let name, let raw = UserDefaults.standard.dictionary(forKey: key)?[name] as? [String: String] else {
            return nil
        }
        return Style(color: raw["color"].flatMap(ChipColor.init(rawValue:)), symbol: raw["symbol"])
    }

    static func save(_ chips: [Chip]) {
        var all: [String: [String: String]] = [:]
        for chip in chips where chip.group == .category {
            var entry: [String: String] = [:]
            entry["color"] = chip.colorName
            entry["symbol"] = chip.symbol
            if !entry.isEmpty { all[chip.label] = entry }
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}
