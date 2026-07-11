import XCTest
import QuartetEngine
@testable import QuartetUI

/// Provider whose streams never finish (yield nothing, never terminate) —
/// models a seat suspended mid-stream so cancellation paths can be exercised.
private struct NeverEndingProvider: ProviderStreaming {
    func stream(request: SeatRequest, apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { _ in
            // Never yields, never finishes. Cancellation of the consuming task
            // ends iteration with nil (no CancellationError) — exactly the
            // stdlib behavior the UI must handle.
        }
    }
}

private struct NeverEndingResolver: ProviderResolving {
    func client(for seat: Seat) throws -> any ProviderStreaming { NeverEndingProvider() }
    func apiKey(for provider: ProviderKind) throws -> String { "test-key" }
}

@MainActor
final class AppModelRunLifecycleTests: XCTestCase {
    private func makeModel(resolver: any ProviderResolving = NeverEndingResolver()) -> AppModel {
        AppModel(seats: SeatConfiguration.defaultSeats(),
                 priceTable: .bundledDefault,
                 resolver: resolver)
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    /// Stop mid-run: the stream ends cleanly (nil, NOT CancellationError) when
    /// the consuming task is cancelled. The UI must reach an explicit terminal
    /// state — no seat left .streaming, runError set, synthesis not left
    /// spinning at .waitingForPanel.
    func testStopMidRunReachesTerminalState() async throws {
        let model = makeModel()
        model.queryText = "never returns"
        model.startRun()

        try await waitUntil { model.seatStates.allSatisfy { $0.status == .streaming } }

        model.cancelRun()
        try await waitUntil { !model.isRunning }

        XCTAssertNotNil(model.runError, "Stop must surface a reason")
        for state in model.seatStates {
            XCTAssertEqual(state.status, .cancelled,
                           "Seat \(state.seat.name) left in \(state.status) after Stop")
        }
        XCTAssertEqual(model.synthesisStatus,
                       .failed("Stopped before synthesis completed."))
        XCTAssertNil(model.lastRecord)
    }

    /// Live usage during a deliberation leg is round-1 base + the leg's LATEST
    /// cumulative snapshot. Two snapshots per leg (Anthropic emits one at
    /// message_start and one at message_delta) must not compound.
    func testDeliberationUsageIsBasePlusLatestSnapshotNotCompounded() throws {
        let model = makeModel()
        model.beginLiveRun()
        let seatID = model.seatStates[0].id

        let round1 = TokenUsage(inputTokens: 100, outputTokens: 50)
        model.apply(.seatBegan(seatID: seatID))
        model.apply(.seatUsage(seatID: seatID, usage: round1))
        model.apply(.seatCompleted(seatID: seatID, text: "round one", usage: round1))

        model.apply(.seatRevisionBegan(seatID: seatID))
        // Cumulative snapshots for the deliberation leg: same input tokens in both.
        let snapshot1 = TokenUsage(inputTokens: 900, outputTokens: 2)
        let snapshot2 = TokenUsage(inputTokens: 900, outputTokens: 40)
        model.apply(.seatUsage(seatID: seatID, usage: snapshot1))
        model.apply(.seatUsage(seatID: seatID, usage: snapshot2))

        let state = try XCTUnwrap(model.seatStates.first { $0.id == seatID })
        XCTAssertEqual(state.usage, round1 + snapshot2,
                       "Expected round-1 base + latest snapshot; compounding snapshots double-counts the leg's input tokens")
    }

    /// A failed revision restores the round-1 text IMMEDIATELY so the
    /// "Revision failed — showing round-1 answer" label is true while
    /// synthesis is still running.
    func testRevisionFailedRestoresRoundOneTextImmediately() throws {
        let model = makeModel()
        model.beginLiveRun()
        let seatID = model.seatStates[0].id

        model.apply(.seatBegan(seatID: seatID))
        model.apply(.seatDelta(seatID: seatID, text: "the round-1 answer"))
        model.apply(.seatCompleted(seatID: seatID, text: "the round-1 answer", usage: nil))

        model.apply(.seatRevisionBegan(seatID: seatID))
        model.apply(.seatRevisionDelta(seatID: seatID, text: "partial revis"))
        model.apply(.seatRevisionFailed(seatID: seatID, message: "boom"))

        let state = try XCTUnwrap(model.seatStates.first { $0.id == seatID })
        XCTAssertEqual(state.text, "the round-1 answer",
                       "The pane must show the kept round-1 answer, not the aborted partial revision")
        XCTAssertEqual(state.revisionFailedMessage, "boom")
        XCTAssertEqual(state.status, .done)
    }

    /// Errors from multiple attachment failures accumulate — a later failure
    /// (or a later clear-at-entry) must not erase an earlier one.
    func testAttachmentErrorsAccumulateWithinOneGesture() async {
        let model = makeModel()
        model.clearAttachmentError()
        // Two undecodable payloads in one gesture.
        await model.addAttachment(imageData: Data("not an image".utf8))
        await model.addAttachment(imageData: Data("also not an image".utf8))
        let error = model.attachmentError ?? ""
        XCTAssertFalse(error.isEmpty)
        XCTAssertEqual(error.components(separatedBy: "\n").count, 2,
                       "Both failures must survive on the error surface: \(error)")
    }
}
