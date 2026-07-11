import SwiftUI
import os
import QuartetEngine
import QuartetProviders

/// Settings window: API keys (Keychain), the four seats, and the price table.
public struct QuartetSettingsView: View {
    @Bindable var model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            APIKeysSettings()
                .tabItem { Label("API Keys", systemImage: "key.fill") }
            SeatsSettings(model: model)
                .tabItem { Label("Seats", systemImage: "person.3.fill") }
            PricesSettings(model: model)
                .tabItem { Label("Prices", systemImage: "dollarsign.circle") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised.fill") }
        }
        .frame(width: 640, height: 460)
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @AppStorage(CrashReporting.optInDefaultsKey) private var shareCrashReports = false

    var body: some View {
        Form {
            Section("Crash & error reports") {
                Toggle("Share crash & error reports", isOn: $shareCrashReports)
                Text("""
                Off by default. When on, anonymized crash reports (stack traces, \
                app/OS version) help fix bugs. Reports NEVER include your prompts, \
                model answers, or API keys — content-bearing fields are stripped \
                before anything is sent. Takes effect at the next launch.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !CrashReporting.buildHasReportingEndpoint() {
                    Label("This build has no reporting endpoint configured — nothing will ever be sent, regardless of this setting.",
                          systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - API Keys

private struct APIKeysSettings: View {
    var body: some View {
        Form {
            ForEach(ProviderKind.allCases) { provider in
                ProviderKeyRow(provider: provider)
            }
            Text("Keys are stored in the macOS Keychain (service \(KeychainStore.service)), never on disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ProviderKeyRow: View {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "settings-ui")

    let provider: ProviderKind

    @State private var key: String = ""
    @State private var status: Status = .unknown
    @State private var testing = false

    enum Status: Equatable {
        case unknown
        case saved
        case pass(String)
        case fail(String)
    }

    var body: some View {
        Section(provider.displayName) {
            HStack {
                SecureField("API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { save() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    test()
                } label: {
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test")
                    }
                }
                .disabled(testing || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            statusLine
        }
        .onAppear { loadExisting() }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .unknown:
            Text("No key stored.").font(.caption).foregroundStyle(.secondary)
        case .saved:
            Label("Key stored in Keychain (untested this session).", systemImage: "checkmark")
                .font(.caption).foregroundStyle(.secondary)
        case .pass(let message):
            Label(message, systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        case .fail(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private func loadExisting() {
        do {
            if let existing = try KeychainStore().key(for: provider), !existing.isEmpty {
                key = existing
                status = .saved
            }
        } catch {
            Self.logger.error("Keychain read in settings failed: \(String(describing: error), privacy: .public)")
            status = .fail("Keychain read failed: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try KeychainStore().setKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
            status = .saved
        } catch {
            Self.logger.error("Keychain save failed: \(String(describing: error), privacy: .public)")
            status = .fail("Keychain save failed: \(error.localizedDescription)")
        }
    }

    private func test() {
        testing = true
        let candidate = key
        Task {
            defer { testing = false }
            do {
                let summary = try await KeyTester().test(provider: provider, apiKey: candidate)
                status = .pass(summary)
            } catch {
                status = .fail(userFacingMessage(for: error))
            }
        }
    }
}

// MARK: - Seats

private struct SeatsSettings: View {
    @Bindable var model: AppModel
    @State private var validationError: String?

    var body: some View {
        Form {
            Section("Quartet seats") {
                ForEach($model.seats) { $seat in
                    HStack(spacing: 8) {
                        Toggle("Anchor", isOn: Binding(
                            get: { seat.isAnchor },
                            set: { newValue in
                                if newValue {
                                    // exactly one anchor: setting one clears the others
                                    for index in model.seats.indices {
                                        model.seats[index].isAnchor = (model.seats[index].id == seat.id)
                                    }
                                }
                                // ignore unsetting: an anchor is required; pick another seat instead
                            }))
                            .toggleStyle(.checkbox)
                            .help("The anchor synthesizes the final answer and extracts dissent. Exactly one seat must be anchor — select another seat to move it.")

                        Picker("", selection: $seat.provider) {
                            ForEach(ProviderKind.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)

                        TextField("model id", text: $seat.modelID)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Restore Defaults") {
                    model.seats = SeatConfiguration.defaultSeats()
                    saveIfValid()
                }
                Spacer()
                Button("Save Seats") { saveIfValid() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func saveIfValid() {
        do {
            try SeatConfiguration.validate(model.seats)
            // Persistence failures surface INLINE here, where the save happened
            // (also mirrored to the main-window warnings banner by the model).
            validationError = model.persistSettings()
        } catch {
            validationError = userFacingMessage(for: error)
        }
    }
}

// MARK: - Prices

private struct PricesSettings: View {
    @Bindable var model: AppModel
    @State private var newModelID = ""
    @State private var newInput = ""
    @State private var newOutput = ""
    @State private var addError: String?
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("Model prices (USD per million tokens)") {
                let keys = model.priceTable.prices.keys.sorted()
                if keys.isEmpty {
                    Text("No prices configured — cost estimates will be unavailable.")
                        .foregroundStyle(.secondary)
                }
                ForEach(keys, id: \.self) { modelID in
                    if let price = model.priceTable.prices[modelID] {
                        HStack {
                            Text(modelID).frame(maxWidth: .infinity, alignment: .leading)
                            PriceField(label: "in", value: price.inputPerMTok) { newValue in
                                model.priceTable.prices[modelID]?.inputPerMTok = newValue
                                saveError = model.persistSettings()
                            }
                            PriceField(label: "out", value: price.outputPerMTok) { newValue in
                                model.priceTable.prices[modelID]?.outputPerMTok = newValue
                                saveError = model.persistSettings()
                            }
                            Button {
                                model.priceTable.prices.removeValue(forKey: modelID)
                                saveError = model.persistSettings()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Remove price for \(modelID)")
                        }
                    }
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Add a model price") {
                HStack {
                    TextField("model id (e.g. google/gemini-3.1-pro-preview)", text: $newModelID)
                        .textFieldStyle(.roundedBorder)
                    TextField("$ in/MTok", text: $newInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    TextField("$ out/MTok", text: $newOutput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Button("Add") { addPrice() }
                }
                if let addError {
                    Label(addError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Seat models without a price show \u{201C}price not set\u{201D} instead of a wrong number. Check each provider's current pricing page before entering values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addPrice() {
        let modelID = newModelID.trimmingCharacters(in: .whitespaces)
        guard !modelID.isEmpty else {
            addError = "Model id is required."
            return
        }
        guard let input = Double(newInput), input >= 0,
              let output = Double(newOutput), output >= 0 else {
            addError = "Prices must be non-negative numbers (USD per million tokens)."
            return
        }
        model.priceTable.prices[modelID] = ModelPrice(inputPerMTok: input, outputPerMTok: output)
        addError = model.persistSettings()
        newModelID = ""
        newInput = ""
        newOutput = ""
    }
}

/// Price editor that commits on BOTH Return and focus loss (typing a value and
/// clicking elsewhere used to silently discard the edit), and re-seeds its text
/// when the underlying value changes externally (e.g. Restore Defaults).
private struct PriceField: View {
    let label: String
    let value: Double
    let commit: (Double) -> Void

    @State private var text: String
    @State private var invalid = false
    @FocusState private var focused: Bool

    init(label: String, value: Double, commit: @escaping (Double) -> Void) {
        self.label = label
        self.value = value
        self.commit = commit
        self._text = State(initialValue: String(value))
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .foregroundStyle(invalid ? .red : .primary)
                .focused($focused)
                .onSubmit { commitIfValid() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commitIfValid() }
                }
                .onChange(of: value) { _, newValue in
                    // External change (another editor, Restore Defaults):
                    // refresh the shadow state unless the user is mid-edit.
                    if !focused { text = String(newValue) }
                }
        }
    }

    private func commitIfValid() {
        if let parsed = Double(text), parsed >= 0 {
            invalid = false
            if parsed != value { commit(parsed) }
        } else {
            invalid = true
        }
    }
}
