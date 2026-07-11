import SwiftUI
import AppKit
import QuartetEngine

/// First-run onboarding wizard (design spec §3):
/// Welcome → Permission heads-up → Keys → Finish.
///
/// The pre-permission explainer deliberately PRECEDES the keys step — the
/// Keychain dialog fires during key save/test, so the warning must come first.
/// Presented as a 640×580 sheet from QuartetRootView; ANY dismissal (finish,
/// skip, Escape) persists the completed flag via `model.dismissOnboarding()`.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    private enum Step: Int, CaseIterable {
        case welcome, permission, keys, finish
    }

    @State private var step: Step = .welcome

    /// Key rows in onboarding order (required providers first). Shares the
    /// exact save/test wiring with Settings via ProviderKeyEntryRow — and
    /// step 4's status list is computed from these live states, never hardcoded.
    @State private var keyRows: [ProviderKeyEntryModel] = [
        ProviderKeyEntryModel(provider: .anthropic),
        ProviderKeyEntryModel(provider: .openrouter),
        ProviderKeyEntryModel(provider: .openai),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Shared top chrome: SKIP, top-right.
            HStack {
                Spacer()
                skipButton
            }
            .padding(.top, 14)
            .padding(.horizontal, 20)

            Group {
                switch step {
                case .welcome: welcomeStep
                case .permission: permissionStep
                case .keys: keysStep
                case .finish: finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            bottomBar
        }
        .frame(width: 640, height: 580)
        .background(QDTheme.ink)
        // Catches EVERY dismissal path (Escape included) — idempotent.
        .onDisappear { model.dismissOnboarding() }
    }

    // MARK: - Shared chrome

    private var skipButton: some View {
        HoverText(text: "SKIP", base: QDTheme.text45, hover: .white) {
            model.dismissOnboarding()
        }
        .accessibilityLabel("Skip onboarding")
    }

    private var bottomBar: some View {
        ZStack {
            // 4 progress dots, bottom-center.
            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? QDTheme.ice : QDTheme.text30)
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            // Back (ghost) / forward (primary), bottom-right.
            HStack(spacing: 10) {
                Spacer()
                switch step {
                case .welcome:
                    Button("Skip for Now") { model.dismissOnboarding() }
                        .buttonStyle(QDGhostButtonStyle())
                        .accessibilityLabel("Skip for now")
                    Button("Set Up Keys →") { step = .permission }
                        .buttonStyle(QDPrimaryButtonStyle())
                        .accessibilityLabel("Set up keys")
                case .permission:
                    Button("← Back") { step = .welcome }
                        .buttonStyle(QDGhostButtonStyle())
                        .accessibilityLabel("Back")
                    Button("Got It — Add Keys →") { step = .keys }
                        .buttonStyle(QDPrimaryButtonStyle())
                        .accessibilityLabel("Got it, add keys")
                case .keys:
                    Button("← Back") { step = .permission }
                        .buttonStyle(QDGhostButtonStyle())
                        .accessibilityLabel("Back")
                    // ALWAYS enabled — skipping keys is allowed (§3).
                    Button("Continue →") { step = .finish }
                        .buttonStyle(QDPrimaryButtonStyle())
                        .accessibilityLabel("Continue")
                case .finish:
                    Button("Open Settings") {
                        model.dismissOnboarding()
                        openSettings()
                    }
                    .buttonStyle(QDGhostButtonStyle())
                    .accessibilityLabel("Open Settings")
                    Button("Start My First Run") { startFirstRun() }
                        .buttonStyle(QDPrimaryButtonStyle())
                        .accessibilityLabel("Start my first run")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func startFirstRun() {
        model.dismissOnboarding()
        // Focus lands in the composer AFTER the sheet has actually gone away —
        // bumping the token while the sheet is still up would lose focus back
        // to the dismissing sheet.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            model.composerFocusToken += 1
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("QUARTET DESK").qdKicker()
            Text("FOUR MODELS. ONE ANSWER.").qdDisplayTitle()

            Group {
                Text("Quartet Desk sends every question to a panel of four frontier models in parallel, then has an anchor model merge them into one answer — with disagreements surfaced, never papered over.")
                Text("One model hides its blind spots. Four models disagree exactly where you should be thinking hardest. That disagreement is the product.")
            }
            .font(.system(size: 13))
            .foregroundStyle(QDTheme.text60)
            .frame(maxWidth: 470, alignment: .leading) // ≈ 54ch
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "square.grid.2x2", lead: "PANEL",
                           text: "Four seats answer independently, streamed live side by side.")
                featureRow(icon: "person.3", lead: "SYNTHESIS",
                           text: "The anchor seat merges the panel into one answer.")
                featureRow(icon: "exclamationmark.bubble", lead: "DISSENT",
                           text: "Material disagreements, listed explicitly. If dissent can't be parsed, we say so — we never fake consensus.")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(icon: String, lead: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(QDTheme.ice)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(lead).qdKicker(emphasized: true)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(QDTheme.text60)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Step 2: Pre-permission explainer

    private var permissionStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("BEFORE WE START").qdKicker()
                Text("ONE DIALOG, ZERO SURPRISES.").qdDisplayTitle()

                Text("When you save or test a key on the next screen, macOS may show a system dialog that looks like this:")
                    .font(.system(size: 13))
                    .foregroundStyle(QDTheme.text60)
                    .fixedSize(horizontal: false, vertical: true)

                mockKeychainDialog
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)

                Group {
                    Text("Why: your keys live in the macOS Keychain — the same encrypted store Safari uses for passwords. macOS guards it per-app and asks the first time an app (or a newly rebuilt copy of it) touches its own entry.")
                    Text("What to do: click “Always Allow”. You'll usually see it once — or again if you rebuild the app from source, because the code signature changes.")
                    Text("We warn you now because a surprise permission dialog mid-paste is bad UX. When this dialog appears, nothing is being sent anywhere — it's strictly between you and macOS.")
                }
                .font(.system(size: 13))
                .foregroundStyle(QDTheme.text60)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Styled SwiftUI MOCK of the Keychain permission dialog (never a
    /// screenshot of Apple UI). Fully inert.
    private var mockKeychainDialog: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(QDTheme.ice)
            Text("QuartetDesk wants to use your confidential information stored in “tv.affirmi.quartetdesk” in your keychain.")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                fakeGhostButton("Deny")
                fakeGhostButton("Allow")
                fakePrimaryButton("Always Allow") // glow ring = "click this one"
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(QDTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(QDTheme.line, lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example of the macOS keychain permission dialog. When it appears, click Always Allow.")
    }

    private func fakeGhostButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .kerning(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(QDTheme.line, lineWidth: 1))
    }

    private func fakePrimaryButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .kerning(0.8)
            .textCase(.uppercase)
            .foregroundStyle(QDTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(QDTheme.ice)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // 1.5px ice glow ring: the "click this one" signal.
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(QDTheme.ice.opacity(0.9), lineWidth: 1.5)
                    .padding(-3)
            )
            .shadow(color: QDTheme.ice.opacity(0.45), radius: 6)
    }

    // MARK: - Step 3: API keys

    private var keysStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API KEYS").qdKicker()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(keyRows) { row in
                        ProviderKeyEntryRow(model: row, chrome: .card)
                    }
                }
            }

            if requiredKeysMissing {
                Text("Heads up: the default quartet needs the Anthropic and OpenRouter keys before a run will start. You can add them anytime in Settings → API Keys.")
                    .font(.system(size: 11))
                    .foregroundStyle(QDTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Fixed privacy footer (§3, verbatim).
            Text("Your keys are stored only in the macOS Keychain on this Mac (service: tv.affirmi.quartetdesk) — never written to a file, never logged, never sent to any Quartet or Affirmi server. Each key is only ever sent to its own provider: Anthropic → api.anthropic.com · OpenAI → api.openai.com · OpenRouter → openrouter.ai.")
                .font(.system(size: 11))
                .foregroundStyle(QDTheme.text45)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 36)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The default quartet needs BOTH Anthropic and OpenRouter before a run
    /// can start — warn (non-blocking) unless both are saved or verified.
    private var requiredKeysMissing: Bool {
        let anthropicOK = keyRows.first { $0.provider == .anthropic }?.hasKey ?? false
        let openrouterOK = keyRows.first { $0.provider == .openrouter }?.hasKey ?? false
        return !(anthropicOK && openrouterOK)
    }

    // MARK: - Step 4: Finish

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("READY").qdKicker()
            Text("THE PANEL IS SEATED.").qdDisplayTitle()

            // Computed from the LIVE row states — never hardcoded.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(keyRows) { row in
                    keyStatusRow(row)
                }
            }
            .padding(.vertical, 4)

            Group {
                Text("Ask anything — the whole panel answers.")
                Text("Try: “Write a launch plan for my product — call out anything risky.” Then open the DISSENT tab to see exactly where the four models disagreed.")
            }
            .font(.system(size: 13))
            .foregroundStyle(QDTheme.text60)
            .frame(maxWidth: 470, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Text("Seats, models, and prices live in Settings (⌘,). Reopen this tour anytime from Help → Welcome to Quartet Desk.")
                .font(.system(size: 11))
                .foregroundStyle(QDTheme.text45)
        }
        .padding(.horizontal, 36)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func keyStatusRow(_ row: ProviderKeyEntryModel) -> some View {
        let name = row.provider.displayName
        HStack(spacing: 8) {
            switch row.status {
            case .verified:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(name) — key verified").foregroundStyle(.white)
            case .saved:
                Image(systemName: "exclamationmark.circle").foregroundStyle(QDTheme.warn)
                Text("\(name) — key saved, not verified").foregroundStyle(.white)
            case .none:
                Image(systemName: "circle.dashed").foregroundStyle(QDTheme.text45)
                Text("\(name) — no key\(row.provider == .openai ? " (optional)" : "")")
                    .foregroundStyle(QDTheme.text60)
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(QDTheme.bad)
                Text("\(name) — key test failed").foregroundStyle(.white)
            }
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }
}

/// Plain-text button with a hover color swap (kicker-styled SKIP).
private struct HoverText: View {
    let text: String
    let base: Color
    let hover: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: .heavy))
                .kerning(2.8)
                .textCase(.uppercase)
                .foregroundStyle(hovering ? hover : base)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
