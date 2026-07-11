import SwiftUI

/// AppSpace brand tokens (mirrors web/app/landing.css #lp custom properties).
/// Single source of truth for the brand color/material system. The About
/// window uses these now; the full UI restyle (design spec §1.5+) adopts them
/// next.
enum QDTheme {
    static let ink     = Color(red: 11/255,  green: 11/255,  blue: 11/255)   // #0b0b0b  window bg
    static let panel   = Color(red: 16/255,  green: 16/255,  blue: 17/255)   // #101011  cards
    static let panel2  = Color(red: 14/255,  green: 14/255,  blue: 15/255)   // #0e0e0f  footers/insets
    static let ice     = Color(red: 146/255, green: 248/255, blue: 255/255)  // #92f8ff  accent
    static let iceHover = Color(red: 182/255, green: 251/255, blue: 255/255) // #b6fbff  hover state
    static let iceDim  = Color(red: 107/255, green: 196/255, blue: 202/255)  // #6bc4ca  muted accent
    static let line    = Color.white.opacity(0.10)                            // hairlines/borders
    static let line2   = Color.white.opacity(0.06)                            // subtle rules
    static let text60  = Color.white.opacity(0.60)                            // secondary text
    static let text45  = Color.white.opacity(0.45)                            // meta/kickers
    static let text30  = Color.white.opacity(0.30)                            // disabled/ghost
    static let bad     = Color(red: 255/255, green: 90/255,  blue: 77/255)   // #ff5a4d  errors
    static let warn    = Color(red: 255/255, green: 180/255, blue: 84/255)   // #ffb454  warnings (unpriced models, revision-failed)
}
