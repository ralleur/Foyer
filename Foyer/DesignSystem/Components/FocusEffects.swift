import SwiftUI

/// Card-like focus: scale + shadow, animated, honouring Reduce Motion.
struct FocusLiftModifier: ViewModifier {
    let isFocused: Bool
    var scale: CGFloat = CardSize.focusScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? scale : 1)
            .shadow(color: .black.opacity(isFocused ? 0.55 : 0), radius: isFocused ? 28 : 0, y: isFocused ? 16 : 0)
            .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
    }
}

extension View {
    func focusLift(_ isFocused: Bool, scale: CGFloat = CardSize.focusScale) -> some View {
        modifier(FocusLiftModifier(isFocused: isFocused, scale: scale))
    }
}

/// Button style for artwork cards: the label is the artwork; focus lifts it.
struct CardButtonStyleFoyer: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .focusLift(isFocused)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Large pill button for primary actions (Play, Sign In).
struct PillButtonStyle: ButtonStyle {
    var prominent: Bool = true
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.button)
            .foregroundStyle(isFocused ? Color.black : Color.foyerPrimaryText)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s + 2)
            .frame(minHeight: 72)
            .background(
                Capsule().fill(isFocused ? Color.white : (prominent ? Color.white.opacity(0.18) : Color.white.opacity(0.1)))
            )
            .scaleEffect(isFocused ? 1.04 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 18, y: 10)
            .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Compact icon button (favorite, watched, info).
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(isFocused ? Color.black : Color.foyerPrimaryText)
            .frame(width: 72, height: 72)
            .background(Circle().fill(isFocused ? Color.white : Color.white.opacity(0.14)))
            .scaleEffect(isFocused ? 1.06 : 1)
            .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Row-style button used in settings and lists.
struct ListRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.button).fill(isFocused ? Color.white : Color.white.opacity(0.06)))
            .foregroundStyle(isFocused ? Color.black : Color.foyerPrimaryText)
            .scaleEffect(isFocused ? 1.01 : 1)
            .animation(Motion.focus, value: isFocused)
    }
}

/// Quiet style for focusable text blocks (e.g. the overview that opens in full): the text brightens
/// and gets a faint backing instead of the system's bright platter.
struct TextBlockButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.foyerPrimaryText : Color.foyerSecondaryText)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Color.white.opacity(isFocused ? 0.1 : 0)))
            .padding(.horizontal, -Spacing.s)
            .padding(.vertical, -Spacing.xs)
            .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
