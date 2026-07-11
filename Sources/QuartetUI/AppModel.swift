import Foundation
import Observation
import os
import QuartetEngine
import QuartetProviders
import QuartetExport

/// Live per-seat UI state during a run.
struct SeatLiveState: Identifiable {
    enum Status: Equatable {
        case idle
        case streaming
        case revising
        case done
        case failed(String)
        /// The run was stopped (user Stop or a stream error) before this seat
        /// reached a terminal state. Never left as .streaming — a dead run must
        /// not render live spinners.
        case cancelled
    }

    var seat: Seat
    var status: Status = .idle
    var text: String = ""
    var usage: TokenUsage?
    var revisionFailedMessage: String?
    /// True when the seat's answer was cut off at the provider token limit
    /// (stop reason "max_tokens"/"length") — surfaced, never shown as complete.
    var truncated: Bool = false
    /// Round-1 usage snapshot, taken when a deliberation leg begins. Live usage
    /// during revision is base + latest leg snapshot (never snapshot+snapshot,
    /// which double-counts the leg's input tokens).
    var roundOneUsage: TokenUsage?
    /// Round-1 answer text, stashed when a deliberation leg begins so a failed
    /// revision can restore it immediately (the transcript sync at .finished
    /// may be a minute of synthesis away).
    var preRevisionText: String = ""

    var id: UUID { seat.id }
}

enum SynthesisLiveStatus: Equatable {
    case idle
    case waitingForPanel
    case streaming
    case done
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "appmodel")

    // MARK: Configuration
    var seats: [Seat]
    var priceTable: PriceTable
    /// Non-fatal problems worth showing once (corrupt settings, unreadable history files).
    var startupWarnings: [String] = []

    // MARK: Composer
    var queryText: String = ""
    var attachments: [ImageAttachment] = []
    var deliberate: Bool = false
    var attachmentError: String?

    // MARK: Result tab (lifted out of the view so it survives view identity
    // changes and is drivable by the smoke harness)
    var resultTab: ResultTab = .answer

    // MARK: Run state
    private(set) var isRunning = false
    private(set) var seatStates: [SeatLiveState] = []
    private(set) var liveAnswerText: String = ""
    private(set) var synthesisStatus: SynthesisLiveStatus = .idle
    private(set) var lastRecord: RunRecord?
    var runError: String?

    // MARK: History
    private(set) var history: [RunRecord] = []
    var selectedRecordID: UUID?

    private var runTask: Task<Void, Never>?
    private var settingsStore: SettingsStore?
    private var historyStore: RunHistoryStore?
    /// Provider resolver used for runs. Injected so tests can drive the full
    /// run lifecycle with fakes; the app uses the Keychain-backed default.
    private let resolver: any ProviderResolving

    /// Test-only: in-memory model with an injected resolver. Touches no disk
    /// stores, so tests never read or clobber the user's real settings/history.
    init(seats: [Seat], priceTable: PriceTable, resolver: any ProviderResolving) {
        self.seats = seats
        self.priceTable = priceTable
        self.resolver = resolver
    }

    init() {
        resolver = KeychainProviderResolver()
        do {
            let store = try SettingsStore()
            settingsStore = store
            let (settings, loadError) = store.load()
            seats = settings.seats
            priceTable = settings.priceTable
            if let loadError { startupWarnings.append(loadError) }
        } catch {
            Self.logger.error("Settings store unavailable: \(String(describing: error), privacy: .public)")
            seats = SeatConfiguration.defaultSeats()
            priceTable = .bundledDefault
            startupWarnings.append("Settings could not be persisted (\(error.localizedDescription)); using in-memory defaults.")
        }

        do {
            let store = try RunHistoryStore()
            historyStore = store
            let result = store.loadAll()
            history = result.records
            for failure in result.failures {
                startupWarnings.append("History file \(failure.file) failed to load: \(failure.error)")
            }
        } catch {
            Self.logger.error("History store unavailable: \(String(describing: error), privacy: .public)")
            startupWarnings.append("Run history could not be opened (\(error.localizedDescription)); runs will not be persisted this session.")
        }
    }

    // MARK: - Settings persistence

    func persistSettings() {
        guard let settingsStore else { return }
        do {
            try settingsStore.save(PersistedSettings(seats: seats, priceTable: priceTable))
        } catch {
            Self.logger.error("Settings save failed: \(String(describing: error), privacy: .public)")
            startupWarnings.append("Saving settings failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Attachments

    /// Clears the attachment error surface. Called ONCE at the start of each
    /// user gesture (drop / paste / file pick) — NOT per file, so one file's
    /// failure message is never erased by the next file's attempt.
    func clearAttachmentError() {
        attachmentError = nil
    }

    /// Accumulates (never overwrites) attachment failures so a multi-file
    /// gesture surfaces every failure, not just the last one.
    func appendAttachmentError(_ message: String) {
        Self.logger.error("Attachment error: \(message, privacy: .public)")
        if let existing = attachmentError, !existing.isEmpty {
            attachmentError = existing + "\n" + message
        } else {
            attachmentError = message
        }
    }

    func addAttachment(imageData: Data) async {
        do {
            let attachment = try await Task.detached(priority: .userInitiated) {
                try ImagePipeline.process(imageData)
            }.value
            attachments.append(attachment)
        } catch {
            appendAttachmentError(error.localizedDescription)
        }
    }

    /// Reads + processes a file entirely off the main thread, then appends on
    /// return. Callers iterate their URL lists inside ONE task, so appends are
    /// deterministic in the user's selection order.
    func addAttachment(contentsOf url: URL) async {
        do {
            let attachment = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url) // file IO off the main thread
                return try ImagePipeline.process(data)
            }.value
            attachments.append(attachment)
        } catch {
            appendAttachmentError("Could not attach \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    // MARK: - Run lifecycle

    var canRun: Bool {
        !isRunning && !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func startRun() {
        guard canRun else { return }
        beginLiveRun()

        let query = QuartetQuery(text: queryText, images: attachments)
        let config = QuartetRunConfig(seats: seats, deliberate: deliberate, priceTable: priceTable)
        let orchestrator = QuartetOrchestrator(resolver: resolver)
        let stream = orchestrator.run(query: query, config: config)

        runTask = Task { [weak self] in
            do {
                for try await event in stream {
                    self?.apply(event)
                }
                // AsyncThrowingStream does NOT throw CancellationError when the
                // iterating task is cancelled — next() resumes nil and the loop
                // exits CLEANLY. So end-of-stream-without-a-record IS the
                // cancellation signal, and must become an explicit terminal
                // state (otherwise seats stay .streaming forever).
                if let self, self.lastRecord == nil {
                    self.markRunStopped(message: "Run stopped.")
                }
            } catch is CancellationError {
                // Belt and braces only — see above; this branch cannot fire today.
                self?.markRunStopped(message: "Run cancelled.")
            } catch {
                Self.logger.error("Run stream failed: \(String(describing: error), privacy: .public)")
                self?.markRunStopped(message: userFacingMessage(for: error))
            }
            self?.isRunning = false
        }
    }

    /// Resets all live-run state. Internal (not private) so tests can drive
    /// apply() deterministically without a network run.
    func beginLiveRun() {
        runError = nil
        selectedRecordID = nil
        isRunning = true
        seatStates = seats.map { SeatLiveState(seat: $0) }
        liveAnswerText = ""
        synthesisStatus = .waitingForPanel
        lastRecord = nil
    }

    func cancelRun() {
        runTask?.cancel()
    }

    /// Terminal cleanup for a run that ended without a `.finished` record
    /// (user Stop, or a thrown stream error): surfaces the reason and flips
    /// every non-terminal seat + synthesis state so the UI never renders live
    /// spinners for a dead run.
    private func markRunStopped(message: String) {
        runError = message
        for index in seatStates.indices {
            switch seatStates[index].status {
            case .idle, .streaming, .revising:
                seatStates[index].status = .cancelled
            case .done, .failed, .cancelled:
                break
            }
        }
        if synthesisStatus == .waitingForPanel || synthesisStatus == .streaming {
            synthesisStatus = .failed("Stopped before synthesis completed.")
        }
    }

    /// Internal (not private) so tests can feed canned event sequences.
    func apply(_ event: QuartetEvent) {
        switch event {
        case .seatBegan(let seatID):
            updateSeat(seatID) { $0.status = .streaming }
        case .seatDelta(let seatID, let text):
            updateSeat(seatID) { $0.text += text }
        case .seatUsage(let seatID, let usage):
            updateSeat(seatID) { state in
                // Usage chunks are CUMULATIVE per-leg snapshots (providers emit
                // several per call). During a deliberation leg the live total is
                // round-1 base + the leg's LATEST snapshot — never snapshot
                // added to snapshot, which double-counts the leg's input tokens.
                if state.status == .revising {
                    let base = state.roundOneUsage ?? TokenUsage(inputTokens: 0, outputTokens: 0)
                    state.usage = base + usage
                } else {
                    state.usage = usage
                }
            }
        case .seatCompleted(let seatID, let text, _):
            updateSeat(seatID) { $0.status = .done; $0.text = text }
        case .seatTruncated(let seatID):
            updateSeat(seatID) { $0.truncated = true }
        case .seatFailed(let seatID, let message):
            updateSeat(seatID) { $0.status = .failed(message) }
        case .seatRevisionBegan(let seatID):
            updateSeat(seatID) { state in
                state.status = .revising
                state.preRevisionText = state.text
                state.roundOneUsage = state.usage
                state.text = ""
            }
        case .seatRevisionDelta(let seatID, let text):
            updateSeat(seatID) { $0.text += text }
        case .seatRevised(let seatID, let text, _):
            updateSeat(seatID) { $0.status = .done; $0.text = text }
        case .seatRevisionFailed(let seatID, let message):
            updateSeat(seatID) { state in
                state.status = .done
                state.revisionFailedMessage = message
                // Orchestrator kept the round-1 answer — restore it NOW so the
                // "showing round-1 answer" label is immediately true (the
                // transcript sync at .finished may be a minute of synthesis away).
                state.text = state.preRevisionText
            }
        case .synthesisBegan:
            synthesisStatus = .streaming
            liveAnswerText = ""
        case .synthesisDelta(let text):
            liveAnswerText += text
        case .synthesisFailed(let message):
            synthesisStatus = .failed(message)
        case .finished(let record):
            finishRun(with: record)
        }
    }

    private func finishRun(with record: RunRecord) {
        lastRecord = record
        if record.synthesizedAnswer != nil {
            synthesisStatus = .done
            liveAnswerText = record.synthesizedAnswer ?? ""
        } else if case .failed = synthesisStatus {
            // keep the failure message
        } else {
            synthesisStatus = .failed(record.synthesisError ?? "Synthesis did not run.")
        }
        // Sync final seat texts (deliberation fallbacks, exact final answers).
        for transcript in record.seats {
            updateSeat(transcript.id) { state in
                state.text = transcript.text
                state.usage = transcript.usage
                state.truncated = transcript.truncated
                if let error = transcript.errorMessage {
                    state.status = .failed(error)
                } else {
                    state.status = .done
                }
            }
        }
        history.insert(record, at: 0)
        if let historyStore {
            do {
                try historyStore.save(record)
            } catch {
                Self.logger.error("Run save failed: \(String(describing: error), privacy: .public)")
                runError = "Run finished but could not be saved to history: \(error.localizedDescription)"
            }
        }
    }

    private func updateSeat(_ id: UUID, _ mutate: (inout SeatLiveState) -> Void) {
        guard let index = seatStates.firstIndex(where: { $0.id == id }) else { return }
        mutate(&seatStates[index])
    }

    // MARK: - History

    func deleteRecord(_ id: UUID) {
        history.removeAll { $0.id == id }
        if selectedRecordID == id { selectedRecordID = nil }
        if let historyStore {
            do {
                try historyStore.delete(id: id)
            } catch {
                Self.logger.error("History delete failed: \(String(describing: error), privacy: .public)")
                runError = "Could not delete run from disk: \(error.localizedDescription)"
            }
        }
    }

    var selectedRecord: RunRecord? {
        guard let selectedRecordID else { return nil }
        return history.first { $0.id == selectedRecordID }
    }

    /// Cost of the currently displayed run (selected history record or last live run).
    var displayedCost: CostBreakdown? {
        (selectedRecord ?? lastRecord)?.cost
    }
}
