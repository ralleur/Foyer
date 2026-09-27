import SwiftUI

// Design tokens. No magic numbers elsewhere.

enum Spacing {
    static let xs: CGFloat = 8
    static let s: CGFloat = 16
    static let m: CGFloat = 24
    static let l: CGFloat = 40
    static let xl: CGFloat = 60
    /// Horizontal screen margin (tvOS safe area is 90/60 already; this is the content inset inside it).
    static let screenEdge: CGFloat = 80
    static let rowGap: CGFloat = 48
}

enum Radius {
    static let poster: CGFloat = 12
    static let card: CGFloat = 14
    static let button: CGFloat = 16
    static let panel: CGFloat = 28
    static let badge: CGFloat = 6
}

enum CardSize {
    /// Portrait poster (2:3). Six per row at 1920 pt with margins.
    static let poster = CGSize(width: 240, height: 360)
    /// Landscape thumbnail (16:9). Four per row.
    static let landscape = CGSize(width: 400, height: 225)
    static let landscapeLarge = CGSize(width: 520, height: 292)
    static let square = CGSize(width: 260, height: 260)
    static let personAvatar: CGFloat = 180
    static let focusScale: CGFloat = 1.06
}

enum Typography {
    static let heroTitle = Font.system(size: 64, weight: .bold)
    static let screenTitle = Font.system(size: 48, weight: .bold)
    static let sectionTitle = Font.system(size: 34, weight: .semibold)
    static let cardTitle = Font.system(size: 26, weight: .medium)
    static let cardSubtitle = Font.system(size: 23, weight: .regular)
    static let body = Font.system(size: 29, weight: .regular)
    static let bodyEmphasis = Font.system(size: 29, weight: .semibold)
    static let meta = Font.system(size: 25, weight: .medium)
    static let caption = Font.system(size: 21, weight: .medium)
    static let button = Font.system(size: 31, weight: .semibold)
    static let mono = Font.system(size: 22, weight: .regular, design: .monospaced)
}

enum Motion {
    static let focus = Animation.easeOut(duration: 0.18)
    static let overlay = Animation.easeInOut(duration: 0.25)
    static let content = Animation.easeInOut(duration: 0.3)
}

extension Color {
    static let velaBackground = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let velaSurface = Color(white: 0.16)
    static let velaSurfaceElevated = Color(white: 0.22)
    static let velaPrimaryText = Color.white
    static let velaSecondaryText = Color(white: 0.72)
    static let velaTertiaryText = Color(white: 0.5)
    static let velaAccent = Color(red: 0.98, green: 0.72, blue: 0.24)
    static let velaProgress = Color(red: 0.98, green: 0.72, blue: 0.24)
    static let velaDanger = Color(red: 0.95, green: 0.35, blue: 0.3)
    static let velaOverlayScrim = Color.black.opacity(0.55)
}
