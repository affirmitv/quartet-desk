import XCTest
@testable import QuartetEngine

/// Fake provider with per-model scripts including stop reasons and hangs.
private struct ScriptedProvider: ProviderStreaming {
    enum Script: Sendable {
        case answer(String, usage: TokenUsage, stopReason: String)
        /// Emits a delta then never terminates — models a wedged stream.
        case hang
    }

    let scripts: [String: Script]
    let synthesisScript: Script?

    func stream(request: SeatRequest, apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
        let isSynthesis = request.messages.contains {
            $0.role == .system && $0.text.contains(PromptAssembly.dissentMarker)
        }
        let script: Script? = isSynthesis ? synthesisScript : scripts[request.seat.modelID]
        return AsyncThrowingStream { continuation in
            switch script {
            case .answer(let text, let usage, let stopReason):
                continuation.yield(.textDelta(text))
                continuation.yield(.usage(usage))
                continuation.yield(.completed(stopReason: stopReason))
                continuation.finish()
            case .hang:
                continuation.yield(.textDelta("still going"))
                // never finishes
            case nil:
                continuation.finish(throwing: ProviderError.api(message: "no script for \(request.seat.modelID)"))
            }
        }
    }
}

private struct ScriptedResolver: ProviderResolving {
    let provider: ScriptedProvider
    func client(for seat: Seat) throws -> any ProviderStreaming { provider }
    func apiKey(for provider: ProviderKind) throws -> String { "test-key" }
}

final class TimeoutAndTruncationTests: XCTestCase {
    private let usage = TokenUsage(inputTokens: 10, outputTokens: 5)
    private let synthesisOK = "Answer.\n===DISSENT===\n```json\n{\"dissents\": []}\n```"

    private func drain(_ stream: AsyncThrowingStream<QuartetEvent, Error>) async throws -> (events: [QuartetEvent], record: RunRecord?) {
        var events: [QuartetEvent] = []
        var record: RunRecord?
        for try await event in stream {
            events.append(event)
            if case .finished(let r) = event { record = r }
        }
        return (events, record)
    }

    /// A seat whose stream hangs forever fails with timedOut after the
    /// per-call wall-clock limit — a wedged provider can never hang a run.
    func testHangingSeatFailsWithWallClockTimeout() async throws {
        let provider = ScriptedProvider(
            scripts: [
                "claude-opus-4-8": .answer("A1", usage: usage, stopReason: "end_turn"),
                "openai/gpt-5.6-sol-pro": .hang,
                "google/gemini-3.1-pro-preview": .answer("A3", usage: usage, stopReason: "end_turn"),
                "qwen/qwen3.7-max": .answer("A4", usage: usage, stopReason: "end_turn"),
            ],
            synthesisScript: .answer(synthesisOK, usage: usage, stopReason: "end_turn"))

        let orchestrator = QuartetOrchestrator(resolver: ScriptedResolver(provider: provider))
        let config = QuartetRunConfig(seats: SeatConfiguration.defaultSeats(),
                                      perCallWallClockSeconds: 0.2)
        let start = Date()
        let (_, record) = try await drain(orchestrator.run(query: QuartetQuery(text: "Q"), config: config))

        let r = try XCTUnwrap(record)
        let hung = try XCTUnwrap(r.seats.first { $0.modelID == "openai/gpt-5.6-sol-pro" })
        XCTAssertFalse(hung.succeeded)
        XCTAssertTrue(hung.errorMessage?.contains("wall-clock") == true,
                      "Expected the exact timeout error, got: \(hung.errorMessage ?? "nil")")
        // Non-anchor timeout degrades gracefully: synthesis still runs.
        XCTAssertEqual(r.synthesizedAnswer, "Answer.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "Timeout must actually cut the hang short")
    }

    /// max_tokens / length stop reasons are surfaced as truncation — kept text,
    /// explicit flag, .seatTruncated event, and a note to the synthesizer.
    func testMaxTokensStopReasonMarksSeatTruncated() async throws {
        let provider = ScriptedProvider(
            scripts: [
                "claude-opus-4-8": .answer("A1", usage: usage, stopReason: "end_turn"),
                "openai/gpt-5.6-sol-pro": .answer("cut off mid-answ", usage: usage, stopReason: "length"),
                "google/gemini-3.1-pro-preview": .answer("A3", usage: usage, stopReason: "end_turn"),
                "qwen/qwen3.7-max": .answer("A4", usage: usage, stopReason: "max_tokens"),
            ],
            synthesisScript: .answer(synthesisOK, usage: usage, stopReason: "end_turn"))

        let orchestrator = QuartetOrchestrator(resolver: ScriptedResolver(provider: provider))
        let (events, record) = try await drain(
            orchestrator.run(query: QuartetQuery(text: "Q"),
                             config: QuartetRunConfig(seats: SeatConfiguration.defaultSeats())))

        let r = try XCTUnwrap(record)
        XCTAssertTrue(try XCTUnwrap(r.seats.first { $0.modelID == "openai/gpt-5.6-sol-pro" }).truncated)
        XCTAssertTrue(try XCTUnwrap(r.seats.first { $0.modelID == "qwen/qwen3.7-max" }).truncated)
        XCTAssertFalse(try XCTUnwrap(r.seats.first { $0.modelID == "claude-opus-4-8" }).truncated)
        XCTAssertEqual(events.filter {
            if case .seatTruncated = $0 { return true }; return false
        }.count, 2)
        // Truncated seats keep their (partial) text — flagged, never hidden or faked.
        XCTAssertEqual(try XCTUnwrap(r.seats.first { $0.modelID == "openai/gpt-5.6-sol-pro" }).text,
                       "cut off mid-answ")
    }

    func testSynthesisMaxTokensMarksRecordTruncated() async throws {
        let provider = ScriptedProvider(
            scripts: [
                "claude-opus-4-8": .answer("A1", usage: usage, stopReason: "end_turn"),
                "openai/gpt-5.6-sol-pro": .answer("A2", usage: usage, stopReason: "end_turn"),
                "google/gemini-3.1-pro-preview": .answer("A3", usage: usage, stopReason: "end_turn"),
                "qwen/qwen3.7-max": .answer("A4", usage: usage, stopReason: "end_turn"),
            ],
            // Cut off before the dissent block: parser fails closed AND the flag is set.
            synthesisScript: .answer("Half an ans", usage: usage, stopReason: "max_tokens"))

        let orchestrator = QuartetOrchestrator(resolver: ScriptedResolver(provider: provider))
        let (_, record) = try await drain(
            orchestrator.run(query: QuartetQuery(text: "Q"),
                             config: QuartetRunConfig(seats: SeatConfiguration.defaultSeats())))

        let r = try XCTUnwrap(record)
        XCTAssertTrue(r.synthesisTruncated)
        guard case .extractionFailed = r.dissent else {
            return XCTFail("Dissent must fail closed when the JSON tail was cut off")
        }
    }

    /// The synthesizer prompt explicitly flags truncated panel answers.
    func testSynthesisPromptFlagsTruncatedAnswers() {
        let prompt = PromptAssembly.synthesisUserPrompt(
            query: "Q",
            answers: [
                PanelAnswer(seatName: "Seat 1", modelID: "m1", text: "full", truncated: false),
                PanelAnswer(seatName: "Seat 2", modelID: "m2", text: "partial", truncated: true),
            ],
            failures: [])
        XCTAssertTrue(prompt.contains("Seat 2 (m2) — TRUNCATED"))
        XCTAssertTrue(prompt.contains("CUT OFF at the provider's token limit"))
        XCTAssertFalse(prompt.contains("Seat 1 (m1) — TRUNCATED"))
    }

    /// Old history JSON (no truncated keys) still decodes.
    func testRecordDecodingDefaultsTruncationFlagsForOldFiles() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "createdAt": "2026-07-01T00:00:00Z",
          "queryText": "Q",
          "imageCount": 0,
          "deliberate": false,
          "seats": [{
            "id": "00000000-0000-0000-0000-000000000002",
            "seatName": "Seat 1",
            "provider": "anthropic",
            "modelID": "claude-opus-4-8",
            "isAnchor": true,
            "text": "A",
            "revisionFailed": false
          }],
          "synthesizedAnswer": "A",
          "dissent": {"parsed": {"_0": []}},
          "cost": {"knownUSD": 0, "unknownModels": []}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(RunRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(record.synthesisTruncated)
        XCTAssertFalse(record.seats[0].truncated)
    }
}
