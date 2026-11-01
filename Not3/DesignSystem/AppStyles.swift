import SwiftUI

// All iOS 26-only APIs (Liquid Glass) live in this file behind `#available`.
// Screens only call these modifiers, so dropping iOS 18 later means editing one place.

extension View {
    /// Rounded pill chip. Selected = accent color.
    @ViewBuilder
    func appChipStyle(isOn: Bool) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(
                isOn ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
                in: .capsule
            )
        } else {
            self.background(
                isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.thinMaterial),
                in: .capsule
            )
        }
    }

    /// Main call-to-action button (yellow, full width).
    @ViewBuilder
    func appPrimaryButton() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .foregroundStyle(.black)
                .controlSize(.large)
        } else {
            self.buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(.black)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
        }
    }

    /// Circular floating button (back, more, compose) used outside the system toolbar.
    @ViewBuilder
    func appCircleButton() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }

    /// Sheet for the 12:00 check-in: near full height like the design (morning, mood, afternoon,
    /// time and the if–then plan do not fit a half sheet without hiding rows behind "Lưu kế hoạch").
    func appCheckInSheet() -> some View {
        self.presentationDetents([.large])
            .presentationDragIndicator(.visible)
    }
}

/// Groups chips so glass shapes blend correctly on iOS 26.
struct ChipGroupContainer<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                FlowLayout(spacing: spacing) { content }
            }
        } else {
            FlowLayout(spacing: spacing) { content }
        }
    }
}
