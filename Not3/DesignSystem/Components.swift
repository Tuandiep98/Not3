import SwiftUI

/// Tappable chip — the primary input unit ("chạm trước, gõ sau").
struct ChipButton: View {
    let title: String
    var isOn: Bool = false
    var systemImage: String?
    /// Colour of `systemImage` while the chip is off (a category's colour).
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint ?? Color.primary)
                } else if let tint {
                    Circle().fill(tint).frame(width: 8, height: 8)
                }
                Text(title)
            }
            .font(.subheadline.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Color.black : Color.primary)
            .padding(.horizontal, 15)
            .frame(minHeight: 38)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .appChipStyle(isOn: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Round checkbox like Apple Notes checklists.
struct CheckCircle: View {
    let isOn: Bool
    var size: CGFloat = 24
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isOn {
                    Circle().fill(Theme.accent)
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(.black)
                } else {
                    Circle().strokeBorder(Theme.folderIcon, lineWidth: 1.6)
                }
            }
            .frame(width: size, height: size)
            .frame(width: Theme.minTouch, height: Theme.minTouch)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Bỏ đánh dấu: \(label)" : "Đánh dấu xong: \(label)")
        .sensoryFeedback(.success, trigger: isOn) { _, new in new }
    }
}

/// Small rounded tag (category, duration) on note rows.
struct TagView: View {
    let text: String
    var highlighted = true

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(highlighted ? Theme.tagInk : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(highlighted ? Theme.tagBackground : Theme.chipOff, in: .capsule)
    }
}

/// Section title used inside sheets ("Sáng nay đã làm", …).
struct SheetSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wrapping layout for chip rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
