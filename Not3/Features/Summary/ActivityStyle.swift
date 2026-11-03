import SwiftUI

// Look of "Tổng kết tuần" v2 (canvas "Not3 · Tổng kết tuần v2"): Screen Time / Health style.
// Categorical colours are Apple system colours in a CVD-checked order (blue, orange, teal,
// purple, pink, gray); orange and teal are low-contrast on white, so they always carry a text
// label and a value. Heat map: one yellow ramp, its own steps in Dark Mode.

extension ActivityKind {
    var label: String {
        switch self {
        case .code: "Code"
        case .meeting: "Họp"
        case .jira: "Ticket Jira"
        case .category(let name): name
        case .other: "Khác"
        }
    }

    var shortLabel: String {
        switch self {
        case .jira: "Jira"
        default: label
        }
    }

    var color: Color {
        switch self {
        case .code: .blue
        case .meeting: .orange
        case .jira: .teal
        // A colour the user picked for the category wins over the slot colour.
        case .category(let name): CategoryAppearance.style(for: name)?.color?.color
            ?? (ActivityCategorySlots.slot(of: name) == 1 ? .pink : .purple)
        case .other: .gray
        }
    }

    var symbol: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .meeting: "person.2.fill"
        case .jira: "checklist"
        case .category(let name): CategoryAppearance.style(for: name)?.symbol ?? "tag.fill"
        case .other: "ellipsis"
        }
    }

    var sourceLabel: String {
        switch self {
        case .code: "GitHub · ước tính theo phiên"
        case .meeting: "Lịch · đo chính xác"
        case .jira: "Jira log work · đo chính xác"
        case .category, .other: "Việc Not3 · bấm giờ hoặc dự kiến"
        }
    }

    /// Fixed display order: colour follows the kind, never its rank.
    var order: Int {
        switch self {
        case .code: 0
        case .meeting: 1
        case .jira: 2
        case .category(let name): 3 + (ActivityCategorySlots.slot(of: name) ?? 0)
        case .other: 9
        }
    }
}

enum ActivityStyle {
    /// 0 = nothing; then light → dark (light mode) / dim → bright (dark mode).
    static let heatRamp: [Color] = [
        Color(.tertiarySystemFill),
        Color(light: 0xFFE680, dark: 0x5C4300),
        Color(light: 0xF5B800, dark: 0x8F6500),
        Color(light: 0xC98A00, dark: 0xD19A00),
        Color(light: 0x7A5100, dark: 0xFFD60A),
    ]

    static func heatLevel(minutes: Int) -> Int {
        switch minutes {
        case 0: 0
        case ...15: 1
        case ...30: 2
        case ...45: 3
        default: 4
        }
    }

    /// Daily totals in History: 0, < 2h, < 4h, < 7h, ≥ 7h.
    static func dayLevel(minutes: Int) -> Int {
        switch minutes {
        case 0: 0
        case ..<120: 1
        case ..<240: 2
        case ..<420: 3
        default: 4
        }
    }

    /// "3g 10ph", "45ph", "2g"
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)ph" }
        return m == 0 ? "\(h)g" : "\(h)g \(String(format: "%02d", m))ph"
    }

    /// Spoken / long form: "3 giờ 10 phút"
    static func longDuration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) phút" }
        return m == 0 ? "\(h) giờ" : "\(h) giờ \(m) phút"
    }

    static let weekdayNames = ["Thứ Hai", "Thứ Ba", "Thứ Tư", "Thứ Năm", "Thứ Sáu", "Thứ Bảy", "Chủ nhật"]
}

/// Health-style big number: "39 giờ 20 phút" with small grey units.
struct DurationHeadline: View {
    let minutes: Int
    var size: CGFloat = 34

    var body: some View {
        let h = minutes / 60, m = minutes % 60
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if h > 0 {
                number(h)
                unit("giờ").padding(.trailing, 4)
            }
            if m > 0 || h == 0 {
                number(m)
                unit("phút")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ActivityStyle.longDuration(minutes))
    }

    private func number(_ value: Int) -> some View {
        Text("\(value)").font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
    }

    private func unit(_ text: String) -> some View {
        Text(text).font(.system(size: size / 2, weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// Small caps label above a headline ("TỔNG CỘNG", "THỨ TƯ, 29/10").
struct ChartCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Coloured icon + title, like Health highlight cards.
struct HighlightTitle: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
    }
}

/// Screen Time-style proportion bar: one capsule split by kind, hairline gaps.
struct KindShareBar: View {
    let parts: [(kind: ActivityKind, minutes: Int)]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, parts.reduce(0) { $0 + $1.minutes })
            let gaps = CGFloat(max(0, parts.count - 1)) * 1.5
            HStack(spacing: 1.5) {
                ForEach(parts, id: \.kind) { part in
                    Rectangle()
                        .fill(part.kind.color)
                        .frame(width: max(2, (proxy.size.width - gaps) * CGFloat(part.minutes) / CGFloat(total)))
                }
            }
        }
        .frame(height: height)
        .clipShape(.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map { "\($0.kind.label) \(ActivityStyle.longDuration($0.minutes))" }.joined(separator: ", "))
    }
}

/// Legend grid: dot, name, value — three columns.
struct KindLegend: View {
    let parts: [(kind: ActivityKind, minutes: Int)]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
            ForEach(parts, id: \.kind) { part in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Circle().fill(part.kind.color).frame(width: 8, height: 8)
                        Text(part.kind.shortLabel).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(part.minutes > 0 ? ActivityStyle.duration(part.minutes) : "—")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .padding(.leading, 13)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

extension ActivityReport {
    /// Kinds in fixed order with their minutes (zero kinds left out).
    func kindParts(day: Int? = nil) -> [(kind: ActivityKind, minutes: Int)] {
        let source = day.map { perDay[$0] } ?? byKind
        return source.filter { $0.value > 0 }.sorted { $0.key.order < $1.key.order }.map { (kind: $0.key, minutes: $0.value) }
    }
}
