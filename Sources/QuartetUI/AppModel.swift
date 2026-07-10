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
    }

    var seat: Seat
    var status: Status = .idle
    var text: String = ""
    var usage: TokenUsage?
    var revisionFailedMessage: String?

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

    init() {
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

    func addAttachment(imageData: Data) async {
        attachmentError = nil
        do {
            let attachment = try await Task.detached(priority: .userInitiated) {
                try ImagePipeline.process(imageData)
            }.value
            attachments.append(attachment)
        } catch {
            Self.logger.error("Attachment processing failed: \(String(describing: error), privacy: .public)")
            attachmentError = error.localizedDescription
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
        runError = nil
        selectedRecordID = nil
        isRunning = true
        seatStates = seats.map { SeatLiveState(seat: $0) }
        liveAnswerText = ""
        synthesisStatus = .waitingForPanel
        lastRecord = nil

        let query = QuartetQuery(text: queryText, images: attachments)
        let config = QuartetRunConfig(seats: seats, deliberate: deliberate, priceTable: priceTable)
        let orchestrator = QuartetOrchestrator(resolver: KeychainProviderResolver())
        let stream = orchestrator.run(query: query, config: config)

        runTask = Task { [weak self] in
            do {
                for try await event in stream {
                    self?.apply(event)
                }
            } catch is CancellationError {
                self?.runError = "Run cancelled."
            } catch {
                Self.logger.error("Run stream failed: \(String(describing: error), privacy: .public)")
                self?.runError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            self?.isRunning = false
        }
    }

    func cancelRun() {
        runTask?.cancel()
    }

    private func apply(_ event: QuartetEvent) {
        switch event {
        case .seatBegan(let seatID):
            updateSeat(seatID) { $0.status = .streaming }
        case .seatDelta(let seatID, let text):
            updateSeat(seatID) { $0.text += text }
        case .seatUsage(let seatID, let usage):
            updateSeat(seatID) { state in
                // Usage legs accumulate across round 1 + deliberation.
                if state.status == .revising, let existing = state.usage {
                    state.usage = existing + usage
                } else {
                    state.usage = usage
                }
            }
        case .seatCompleted(let seatID, let text, _):
            updateSeat(seatID) { $0.status = .done; $0.text = text }
        case .seatFailed(let seatID, let message):
            updateSeat(seatID) { $0.status = .failed(message) }
        case .seatRevisionBegan(let seatID):
            updateSeat(seatID) { $0.status = .revising; $0.text = "" }
        case .seatRevisionDelta(let seatID, let text):
            updateSeat(seatID) { $0.text += text }
        case .seatRevised(let seatID, let text, _):
            updateSeat(seatID) { $0.status = .done; $0.text = text }
        case .seatRevisionFailed(let seatID, let message):
            updateSeat(seatID) { state in
                state.status = .done
                state.revisionFailedMessage = message
                // Orchestrator kept the round-1 answer; restore it visually on next finished record.
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
