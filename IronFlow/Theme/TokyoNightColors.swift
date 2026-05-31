import SwiftUI

enum TN {
    static let bg        = Color(hex: 0x1a1b26)
    static let card      = Color(hex: 0x24283b)
    static let fg        = Color(hex: 0xc0caf5)
    static let comment   = Color(hex: 0x565f89)
    static let blue      = Color(hex: 0x7aa2f7)
    static let cyan      = Color(hex: 0x7dcfff)
    static let green     = Color(hex: 0x9ece6a)
    static let yellow    = Color(hex: 0xe0af68)
    static let red       = Color(hex: 0xf7768e)
    static let purple    = Color(hex: 0xbb9af7)
    static let magenta   = Color(hex: 0xbb9af7)
    static let orange    = Color(hex: 0xff9e64)
    static let darkCard  = Color(hex: 0x1f2335)
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}
