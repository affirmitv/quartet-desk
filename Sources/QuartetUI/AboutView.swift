import SwiftUI
import AppKit

/// Branded About window (design spec §4). Version + build are read from the
/// bundle — never hardcoded; an em-dash renders if a value is missing.
public struct AboutView: View {
    public init() {}

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    public var body: some View {
        VStack(spacing: 14) {
            // Always the CURRENT icon — no duplicate asset to drift.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("QUARTET DESK")
                .font(.system(size: 22, weight: .heavy))
                .kerning(1.0)
                .foregroundStyle(.white)

            Text("FOUR MODELS. ONE ANSWER.")
                .font(.system(size: 11, weight: .heavy))
                .kerning(2.8)
                .textCase(.uppercase)
                .foregroundStyle(QDTheme.text45)

            Text("Version \(version) (\(build))")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(QDTheme.text60)

            Rectangle()
                .fill(QDTheme.line2)
                .frame(height: 1)
                .padding(.horizontal, 8)

            Text("Affirmi Inc.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)

            Text("© 2026 Affirmi Inc. All rights reserved.")
                .font(.system(size: 11))
                .foregroundStyle(QDTheme.text45)

            Link("appspace.affirmi.tv", destination: URL(string: "https://appspace.affirmi.tv")!)
                .font(.system(size: 12))
                .foregroundStyle(QDTheme.ice)
        }
        .padding(28)
        .frame(width: 340, height: 420)
        .background(QDTheme.ink)
        .preferredColorScheme(.dark)
    }
}
