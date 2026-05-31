import SwiftUI

/// Palette for a UI theme. Slot names mirror the legacy TN enum for drop-in use,
/// but values can differ per phase.
///
/// Note on Peak: the `blue` slot holds the Storm red accent. This lets existing
/// call sites that use `theme.blue` as the brand/primary accent automatically
/// shift to a red brand in Peak without touching each site. `red` still refers
/// to the true warning/danger red in every palette.
struct Theme: Equatable {
    var bg: Color
    var card: Color
    var darkCard: Color
    var fg: Color
    var comment: Color
    var blue: Color      // primary accent (red in Peak)
    var cyan: Color
    var green: Color
    var yellow: Color
    var red: Color       // danger/warning
    var purple: Color
    var magenta: Color
    var orange: Color

    /// True if this is a light palette. Views can use this for adjustments
    /// like navigation bar chrome.
    var isLight: Bool

    static let base = Theme(
        bg:       Color(hex: 0x1a1b26),
        card:     Color(hex: 0x24283b),
        darkCard: Color(hex: 0x1f2335),
        fg:       Color(hex: 0xc0caf5),
        comment:  Color(hex: 0x565f89),
        blue:     Color(hex: 0x7aa2f7),
        cyan:     Color(hex: 0x7dcfff),
        green:    Color(hex: 0x9ece6a),
        yellow:   Color(hex: 0xe0af68),
        red:      Color(hex: 0xf7768e),
        purple:   Color(hex: 0xbb9af7),
        magenta:  Color(hex: 0xbb9af7),
        orange:   Color(hex: 0xff9e64),
        isLight:  false
    )

    /// TokyoNight Storm with red accents. The `blue` slot holds the Storm red
    /// so "primary" UI reads as red. Actual Storm blue is not used by brand sites.
    static let peak = Theme(
        bg:       Color(hex: 0x24283b),
        card:     Color(hex: 0x292e42),
        darkCard: Color(hex: 0x1f2335),
        fg:       Color(hex: 0xc0caf5),
        comment:  Color(hex: 0x565f89),
        blue:     Color(hex: 0xf7768e), // remapped: primary accent = red
        cyan:     Color(hex: 0x7dcfff),
        green:    Color(hex: 0x9ece6a),
        yellow:   Color(hex: 0xe0af68),
        red:      Color(hex: 0xf7768e),
        purple:   Color(hex: 0xbb9af7),
        magenta:  Color(hex: 0xbb9af7),
        orange:   Color(hex: 0xff9e64),
        isLight:  false
    )

    /// TokyoNight Day — the light palette.
    static let deload = Theme(
        bg:       Color(hex: 0xe1e2e7),
        card:     Color(hex: 0xd0d5e3),
        darkCard: Color(hex: 0xc4c8da),
        fg:       Color(hex: 0x3760bf),
        comment:  Color(hex: 0x848cb5),
        blue:     Color(hex: 0x2e7de9),
        cyan:     Color(hex: 0x007197),
        green:    Color(hex: 0x587539),
        yellow:   Color(hex: 0x8c6c3e),
        red:      Color(hex: 0xf52a65),
        purple:   Color(hex: 0x9854f1),
        magenta:  Color(hex: 0x9854f1),
        orange:   Color(hex: 0xb15c00),
        isLight:  true
    )

    static func `for`(_ phase: WorkoutPhase) -> Theme {
        switch phase {
        case .base: return .base
        case .peak: return .peak
        case .deload: return .deload
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .base
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
