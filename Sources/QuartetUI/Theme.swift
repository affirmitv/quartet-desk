import SwiftUI

/// AppSpace brand tokens (mirrors web/app/landing.css #lp custom properties).
/// Single source of truth for the brand color/material/typography system.
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

// MARK: - Typography (design spec §2 — heavy uppercase kickers, SF Pro)
//
// Brand headlines on the web use the licensed "Bison" font, which is NOT
// bundled here (license not cleared for redistribution). The brand CSS falls
// back to -apple-system — SF Pro at .heavy weight, uppercase, tracked, IS the
// brand-correct desktop rendering.

extension View {
    /// Kicker/eyebrow: 11pt heavy UPPERCASE, kerning 2.8 (≈ .28em, matches
    /// landing `.eyebrow`). `emphasized` swaps text45 for ice.
    func qdKicker(emphasized: Bool = false) -> some View {
        self.font(.system(size: 11, weight: .heavy))
            .kerning(2.8)
            .textCase(.uppercase)
            .foregroundStyle(emphasized ? QDTheme.ice : QDTheme.text45)
    }

    /// Display title: 30pt heavy UPPERCASE, tight leading (≈ landing hero
    /// line-height .9).
    func qdDisplayTitle() -> some View {
        self.font(.system(size: 30, weight: .heavy))
            .kerning(0.3)
            .textCase(.uppercase)
            .lineSpacing(0)
            .foregroundStyle(.white)
    }

    /// Section header: 13pt heavy UPPERCASE (card titles, dissent topics).
    func qdSectionHeader() -> some View {
        self.font(.system(size: 13, weight: .heavy))
            .kerning(1.0)
            .textCase(.uppercase)
            .foregroundStyle(.white)
    }

    /// Meta/caption: 11pt medium, text45, tabular digits for counts/prices.
    func qdMeta() -> some View {
        self.font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(QDTheme.text45)
    }
}

// MARK: - Button styles (design spec §1.5)

/// Solid ice CTA: ink text, uppercase, hover → iceHover, pressed → 0.98 scale.
struct QDPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .bold))
                .kerning(0.8)
                .textCase(.uppercase)
                .foregroundStyle(QDTheme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(hovering && isEnabled ? QDTheme.iceHover : QDTheme.ice)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Outline button: clear fill, hairline border. Default hover → ice text +
/// border; a custom `tint` (e.g. QDTheme.bad for Stop) keeps its tint on hover.
struct QDGhostButtonStyle: ButtonStyle {
    var tint: Color = .white
    var hoverTint: Color = QDTheme.ice

    init() {}

    init(tint: Color, hoverTint: Color? = nil) {
        self.tint = tint
        self.hoverTint = hoverTint ?? tint
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint, hoverTint: hoverTint)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let tint: Color
        let hoverTint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        private var current: Color { hovering && isEnabled ? hoverTint : tint }

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .bold))
                .kerning(0.8)
                .textCase(.uppercase)
                .foregroundStyle(current)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(hovering && isEnabled ? hoverTint : QDTheme.line, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
