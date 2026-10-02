import SwiftUI
import UIKit
import CoreText
import MediaAccessibility

/// The subtitle style chosen in Settings › Accessibility › Subtitles and Captions › Style. Vela draws text
/// subtitles itself (overlay over AVPlayer, libass in mpv), so it has to apply the system style explicitly.
struct CaptionStyle: Equatable {
    enum Edge: Equatable { case none, raised, depressed, uniform, dropShadow }

    var fontName: String?
    /// Multiplier of the system's "Text size" (1 = default).
    var relativeSize: CGFloat
    var textColor: UIColor
    /// Highlight directly behind the characters ("Background").
    var backgroundColor: UIColor
    /// Box around the whole subtitle ("Window").
    var windowColor: UIColor
    var windowCornerRadius: CGFloat
    var edge: Edge

    static var current: CaptionStyle {
        let domain = MACaptionAppearanceDomain.user
        func color(_ copy: (MACaptionAppearanceDomain, UnsafeMutablePointer<MACaptionAppearanceBehavior>?) -> Unmanaged<CGColor>,
                   _ opacity: (MACaptionAppearanceDomain, UnsafeMutablePointer<MACaptionAppearanceBehavior>?) -> CGFloat) -> UIColor {
            let base = UIColor(cgColor: copy(domain, nil).takeRetainedValue())
            return base.withAlphaComponent(base.cgColor.alpha * opacity(domain, nil))
        }
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, nil, .default).takeRetainedValue()
        let fontName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        let edge: Edge = switch MACaptionAppearanceGetTextEdgeStyle(domain, nil) {
        case .raised: .raised
        case .depressed: .depressed
        case .uniform: .uniform
        case .dropShadow: .dropShadow
        default: .none
        }
        return CaptionStyle(
            fontName: fontName,
            relativeSize: max(0.5, min(MACaptionAppearanceGetRelativeCharacterSize(domain, nil), 2.5)),
            textColor: color(MACaptionAppearanceCopyForegroundColor, MACaptionAppearanceGetForegroundOpacity),
            backgroundColor: color(MACaptionAppearanceCopyBackgroundColor, MACaptionAppearanceGetBackgroundOpacity),
            windowColor: color(MACaptionAppearanceCopyWindowColor, MACaptionAppearanceGetWindowOpacity),
            windowCornerRadius: MACaptionAppearanceGetWindowRoundedCornerRadius(domain, nil),
            edge: edge
        )
    }

    var logDescription: String {
        func rgba(_ color: UIColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%.2f/%.2f/%.2f@%.2f", r, g, b, a)
        }
        return "font \(fontName ?? "system") ×\(String(format: "%.2f", relativeSize)), text \(rgba(textColor)), background \(rgba(backgroundColor)), window \(rgba(windowColor)), edge \(edge)"
    }

    /// Posted when the user changes the style in Settings.
    static let didChange = Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)

    func font(size: CGFloat, italic: Bool = false) -> Font {
        let pointSize = size * relativeSize
        // System fonts (".AppleSystemUIFontMedium") only resolve through a descriptor, not `UIFont(name:)`.
        var font = fontName.map { UIFont(descriptor: UIFontDescriptor(fontAttributes: [.name: $0]), size: pointSize) }
            ?? .systemFont(ofSize: pointSize, weight: .medium)
        if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: pointSize)
        }
        return Font(font)
    }

    // MARK: mpv (libass) for SubRip/WebVTT; styled ASS keeps its own look (`sub-ass-override=no`)

    var mpvOptions: [(String, String)] {
        var options: [(String, String)] = [("sub-color", Self.mpvColor(textColor))]
        if let fontName { options.append(("sub-font", fontName)) }
        if windowColor.cgColor.alpha > 0.01 || backgroundColor.cgColor.alpha > 0.01 {
            // libass has one box per event: the window colour, or the character background when there is no window.
            let box = windowColor.cgColor.alpha > 0.01 ? windowColor : backgroundColor
            options += [("sub-border-style", "background-box"), ("sub-back-color", Self.mpvColor(box)), ("sub-shadow-offset", "0")]
        } else {
            options.append(("sub-border-style", "outline-and-shadow"))
            switch edge {
            case .none: options += [("sub-border-size", "0"), ("sub-shadow-offset", "0")]
            case .uniform: options += [("sub-border-size", "3"), ("sub-shadow-offset", "0"), ("sub-border-color", "#000000")]
            case .dropShadow, .raised, .depressed: options += [("sub-border-size", "0"), ("sub-shadow-offset", "2"), ("sub-shadow-color", "#B0000000")]
            }
        }
        return options
    }

    /// `#AARRGGBB` as mpv expects it.
    private static func mpvColor(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func hex(_ value: CGFloat) -> String { String(format: "%02X", Int((max(0, min(1, value)) * 255).rounded())) }
        return "#" + hex(a) + hex(r) + hex(g) + hex(b)
    }
}
