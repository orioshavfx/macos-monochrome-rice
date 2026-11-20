import AppKit

/// The app's look in one place. Every accent (selected segment, toggle, active tab line, "In use" badge,
/// selected card border) is taken from `accent`. The accent is read once at launch from
/// ~/.config/rice-settings/config.toml (`accent = "#rrggbb"`, set on the App page); white when unset.
enum Theme {
    static let accent: NSColor = AppConf.readAccent().flatMap { NSColor(hex: $0) } ?? .white

    /// Text drawn on an accent fill: dark on a light accent, white on a dark one
    /// (whichever has the higher contrast ratio against the accent's relative luminance).
    static let onAccent: NSColor = {
        let l = relativeLuminance(accent)
        let contrastWithBlack = (l + 0.05) / 0.05
        let contrastWithWhite = 1.05 / (l + 0.05)
        return contrastWithBlack >= contrastWithWhite ? NSColor.black.withAlphaComponent(0.85) : .white
    }()

    /// Fills on the dark window background.
    static let cardFill = NSColor.white.withAlphaComponent(0.06)
    static let controlFill = NSColor.white.withAlphaComponent(0.08)
    static let selectedFill = NSColor.white.withAlphaComponent(0.12)
    /// Track of a toggle that is off.
    static let toggleOffFill = NSColor.white.withAlphaComponent(0.18)

    static let cardRadius: CGFloat = 14
    /// Left and right margin of a page.
    static let pageMargin: CGFloat = 20
    /// Room above the page title; the window buttons sit over the sidebar, not over the page.
    static let titlebarInset: CGFloat = 16
    static let sidebarWidth: CGFloat = 190

    /// WCAG relative luminance of a colour, 0 (black) to 1 (white).
    static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
}
