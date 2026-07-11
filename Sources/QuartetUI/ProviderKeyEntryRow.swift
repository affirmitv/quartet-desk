import SwiftUI
import AppKit
import os
import QuartetEngine
import QuartetProviders

// MARK: - Shared per-provider key-entry state

/// The ONE key save/test path, shared by Settings → API Keys and the
/// onboarding wizard (§3). All Keychain writes go through
/// `KeychainStore.setKey` (app-owned items → no keychain prompt on later
/// reads); all tests hit the live `KeyTester` endpoints. Never duplicated.
@MainActor
@Observable
final class ProviderKeyEntryModel: Identifiable {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "key-entry")

    let provider: ProviderKind

    var key: String = ""
    private(set) var testing = false
    private(set) var status: Status = .none
    /// Whether a key is PRESENT in the Keychain — tracked separately from
    /// `status` because a failed TEST of a new candidate does not remove or
    /// overwrite a previously stored key. `hasKey` derives from this, so
    /// onboarding can't falsely report a required key as missing after a
    /// failed test attempt.
    private(set) var storedKeyPresent = false

    enum Status: Equatable {
        /// No key in the Keychain and nothing verified.
        case none
        /// A key is in the Keychain but has not been verified this session.
        case saved
        /// Live test passed AND the key is saved (provider summary attached).
        case verified(String)
        /// Test or Keychain failure — message surfaced verbatim, never silent.
        case failed(String)
    }

    init(provider: ProviderKind) {
        self.provider = provider
        loadExisting()
    }

    /// True when this provider has a stored key in the Keychain — regardless
    /// of whether the LAST test attempt failed (the stored key survives a
    /// failed test of a new candidate).
    var hasKey: Bool { storedKeyPresent }

    var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pre-fills from the Keychain (renders masked in the SecureField).
    private func loadExisting() {
        do {
            if let existing = try KeychainStore().key(for: provider), !existing.isEmpty {
                key = existing
                status = .saved
                storedKeyPresent = true
            }
        } catch {
            Self.logger.error("Keychain read failed for \(self.provider.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            status = .failed("Keychain read failed: \(error.localizedDescription)")
        }
    }

    /// Save WITHOUT testing — Settings escape hatch (e.g. entering a known-good
    /// key while offline). Onboarding always uses `testAndSave()`.
    func saveUntested() {
        do {
            try KeychainStore().setKey(trimmedKey, for: provider)
            status = .saved
            storedKeyPresent = true
        } catch {
            Self.logger.error("Keychain save failed for \(self.provider.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            status = .failed("Keychain save failed: \(error.localizedDescription)")
        }
    }

    /// Combined TEST & SAVE: live-tests the entered key against the provider's
    /// own endpoint; on pass, persists it to the Keychain. Any failure is
    /// surfaced verbatim.
    func testAndSave() async {
        testing = true
        defer { testing = false }
        let candidate = trimmedKey
        do {
            let summary = try await KeyTester().test(provider: provider, apiKey: candidate)
            try KeychainStore().setKey(candidate, for: provider)
            status = .verified(summary)
            storedKeyPresent = true
        } catch {
            // NOTE: a failed test does NOT clear storedKeyPresent — the failed
            // candidate was never written, so any previously stored key is
            // still in the Keychain and still usable.
            Self.logger.error("Key test/save failed for \(self.provider.rawValue, privacy: .public): \(redactedDescription(for: error), privacy: .public)")
            status = .failed(userFacingMessage(for: error))
        }
    }

    // MARK: Provider copy (onboarding §3)

    /// Role line explaining what this key powers in the default quartet.
    var roleLine: String {
        switch provider {
        case .anthropic:
            return "Powers Seat 1 — the Anchor (synthesizer). Required for the default quartet."
        case .openrouter:
            return "Powers Seats 2–4 (GPT, Gemini, Qwen) through a single key. Required for the default quartet."
        case .openai:
            return "Optional — only needed if you point a seat directly at OpenAI."
        }
    }

    /// The provider's key-management console page.
    var keyPageURL: URL {
        switch provider {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")!
        }
    }
}

// MARK: - Shared row view

/// Provider key-entry row. `.form` chrome renders inside a Settings
/// grouped-form section; `.card` chrome renders the onboarding provider card.
/// Both drive the SAME `ProviderKeyEntryModel` — one save/test wiring.
struct ProviderKeyEntryRow: View {
    enum Chrome { case form, card }

    @Bindable var model: ProviderKeyEntryModel
    let chrome: Chrome

    var body: some View {
        switch chrome {
        case .form: formBody
        case .card: cardBody
        }
    }

    // MARK: Form chrome (Settings → API Keys)

    @ViewBuilder
    private var formBody: some View {
        HStack {
            secureField
            testAndSaveButton
        }
        statusLine
        HStack(spacing: 12) {
            Button {
                NSWorkspace.shared.open(model.keyPageURL)
            } label: {
                Text("Get your key ↗")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(QDTheme.ice)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the \(model.provider.displayName) key page in your browser")
            Button {
                model.saveUntested()
            } label: {
                Text("Save without testing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(QDTheme.text45)
            }
            .buttonStyle(.plain)
            .disabled(model.trimmedKey.isEmpty)
            .help("Stores the key in the Keychain without a live check (e.g. while offline).")
            .accessibilityLabel("Save \(model.provider.displayName) key without testing")
        }
    }

    // MARK: Card chrome (onboarding §3)

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.provider.displayName)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
            Text(model.roleLine)
                .font(.system(size: 11))
                .foregroundStyle(QDTheme.text45)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Get Your Key ↗") {
                    NSWorkspace.shared.open(model.keyPageURL)
                }
                .buttonStyle(QDGhostButtonStyle())
                .accessibilityLabel("Open the \(model.provider.displayName) key page in your browser")

                secureField

                testAndSaveButton
            }

            statusLine
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QDTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(QDTheme.line, lineWidth: 1))
    }

    // MARK: Shared pieces

    private var secureField: some View {
        SecureField("Paste your key here", text: $model.key)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("\(model.provider.displayName) API key")
    }

    private var testAndSaveButton: some View {
        Button {
            Task { await model.testAndSave() }
        } label: {
            if model.testing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 76)
            } else {
                Text("Test & Save")
            }
        }
        .buttonStyle(QDPrimaryButtonStyle())
        .disabled(model.trimmedKey.isEmpty || model.testing)
        .accessibilityLabel("Test and save \(model.provider.displayName) key")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .none:
            Text("No key stored.")
                .font(.system(size: 11))
                .foregroundStyle(QDTheme.text45)
        case .saved:
            Text("Key already saved (untested this session).")
                .font(.system(size: 11))
                .foregroundStyle(QDTheme.text45)
        case .verified(let summary):
            HStack(spacing: 6) {
                // Deliberate .green (not ice): green = universal "verified";
                // ice is reserved for brand accents.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(QDTheme.text60)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(QDTheme.bad)
                // Full error, verbatim — no silent failures.
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(QDTheme.bad)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
