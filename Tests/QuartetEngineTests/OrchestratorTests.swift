import XCTest
@testable import QuartetEngine

/// Deterministic fake provider: scripts per-seat behavior so the full pipeline
/// (fan-out → synthesis → dissent parse → cost → record) runs without a network.
private struct FakeProvider: ProviderStreaming {
    enum Script: Sendable {
        case answer(String, usage: TokenUsage)
        case fail(ProviderError)
        /// Emits text then ends WITHOUT a terminal chunk — must surface as truncated.
        case truncateAfter(String)
    }

    /// Keyed by model id; synthesis calls are detected via the dissent marker in the prompt.
    let scripts: [String: Script]
    let synthesisScript: Script?

    func stream(request: SeatRequest, apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
        let isSynthesis = request.messages.contains {
            $0.role == .system && $0.text.contains(PromptAssembly.dissentMarker)
        }
        let script: Script? = isSynthesis ? synthesisScript : scripts[request.seat.modelID]
        return AsyncThrowingStream { continuation in
            switch script {
            case .answer(let text, let usage):
                continuation.yield(.textDelta(text))
                continuation.yield(.usage(usage))
                continuation.yield(.completed(stopReason: "end_turn"))
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            case .truncateAfter(let text):
                continuation.yield(.textDelta(text))
                continuation.finish(throwing: ProviderError.truncatedStream(provider: "Fake"))
            case nil:
                continuation.finish(throwing: ProviderError.api(message: "no script for \(request.seat.modelID)"))
            }
        }
    }
}

private struct FakeResolver: ProviderResolving {
    let provider: FakeProvider
    func client(for seat: Seat) throws -> any ProviderStreaming { provider }
    func apiKey(for provider: ProviderKind) throws -> String { "test-key" }
}

final class OrchestratorTests: XCTestCase {
    private func seats() -> [Seat] { SeatConfiguration.defaultSeats() }

    private func drain(_ stream: AsyncThrowingStream<QuartetEvent, Error>) async throws -> (events: [QuartetEvent], record: RunRecord?) {
        var events: [QuartetEvent] = []
        var record: RunRecord?
        for try await event in stream {
            events.append(event)
            if case .finished(let r) = event { record = r }
        }
        return (events, record)
    }

    func testHappyPathProducesRecordWithDissent() async throws {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50)
        let synthesis = """
        Synthesized best answer.
        ===DISSENT===
        ```json
        {"dissents": [{"topic": "T", "who": "Seat 4", "position": "P"}]}
        ```
        """
        let provider = FakeProvider(
            scripts: [
                "claude-opus-4-8": .answer("A1", usage: usage),
                "openai/gpt-5.6-sol-pro": .answer("A2", usage: usage),
                "google/gemini-3.1-pro-preview": .answer("A3", usage: usage),
                "qwen/qwen3.7-max": .answer("A4", usage: usage),
            ],
            synthesisScript: .answer(synthesis, usage: TokenUsage(inputTokens: 400, outputTokens: 80)))

        let orchestrator = QuartetOrchestrator(resolver: FakeResolver(provider: provider))
        let (_, record) = try await drain(orchestrator.run(query: QuartetQuery(text: "Q"),
                                                           config: QuartetRunConfig(seats: seats())))

        let r = try XCTUnwrap(record)
        XCTAssertEqual(r.synthesizedAnswer, "Synthesized best answer.")
        XCTAssertEqual(r.dissent, .parsed([DissentItem(topic: "T", who: "Seat 4", position: "P")]))
        XCTAssertEqual(r.seats.count, 4)
        XCTAssertTrue(r.seats.allSatisfy(\.succeeded))
        XCTAssertNil(r.synthesisError)
        // Cost: opus legs are priced; gemini/qwen have no bundled price and must be flagged.
        XCTAssertEqual(Set(r.cost.unknownModels), Set(["google/gemini-3.1-pro-preview", "qwen/qwen3.7-max"]))
        XCTAssertGreaterThan(r.cost.knownUSD, 0)
    }

    func testSeatFailureIsSurfacedAndSynthesisStillRuns() async throws {
        let usage = TokenUsage(inputTokens: 10, outputTokens: 5)
        let synthesis = "Answer.\n===DISSENT===\n```json\n{\"dissents\": []}\n```"
        let provider = FakeProvider(
            scripts: [
                "claude-opus-4-8": .answer("A1", usage: usage),
                "openai/gpt-5.6-sol-pro": .fail(.http(status: 429, body: "rate limited")),
                "google/gemini-3.1-pro-preview": .answer("A3", usage: usage),
                "qwen/qwen3.7-max": .answer("A4", usage: usage),
            ],
            synthesisScript: .answer(synthesis, usage: usage))

        let orchestrator = QuartetOrchestrator(resolver: FakeResolver(provider: provider))
        let (events, record) = try await drain(orchestrator.run(query: QuartetQuery(text: "Q"),
                                                                config: QuartetRunConfig(seats: seats())))

        let r = try XCTUnwrap(record)
        let failed = try XCTUnwrap(r.seats.first { $0.modelID == "openai/gpt-5.6-sol-pro" })
        XCTAssertNotNil(failed.errorMessage)
        XCTAssertEqual(r.synthesizedAnswer, "Answer.")
        XCTAssertEqual(r.dissent, .parsed([]))
        XCTAssertTrue(events.contains { if case .seatFailed = $0 { return true }; return false })
    }

    func testAnchorFailureMeansNoSynthesisAndDissentNotRun() async throws {
        let usage = TokenUsage(inputTokens: 10, outputTokens: 5)
        let provider = FakeProvider(
            scripts: [
                "claude-opus-4-8": .fail(.api(message: "boom")),
                "openai/gpt-5.6-sol-pro": .answer("A2", usage: usage),
                "google/gemini-3.1-pro-preview": .answer("A3", usage: usage),
                "qwen/qwen3.7-max": .answer("A4", usage: usage),
            ],
            synthesisScript: .answer("should never run", usage: usage))

        let orchestrator = QuartetOrchestrator(resolver: FakeResolver(provider: provider))
        let (events, record) = try await drain(orchestrator.run(query: QuartetQuery(text: "Q"),
                                                                config: QuartetRunConfig(seats: seats())))

        let r = try XCTUnwrap(record)
        XCTAssertNil(r.synthesizedAnswer)
        XCTAssertNotNil(r.synthesisError)
        XCTAssertEqual(r.dissent, .notRun)
        XCTAssertTrue(events.contains { if case .synthesisFailed = $0 { return true }; return false })
    }

    func testTruncatedSeatStreamBecomesSeatFailureNotHalfAnswer() async throws {
        let usage = TokenUsage(inputTokens: 10, outputTokens: 5)
        let synthesis = "Answer.\n===DISSENT===\n```json\n{\"dissents\": []}\n```"
        let provider = FakeProvider(
            scripts: [
                "claude-opus-4-8": .answer("A1", usage: usage),
                "openai/gpt-5.6-sol-pro": .truncateAfter("half an ans"),
                "google/gemini-3.1-pro-preview": .answer("A3", usage: usage),
                "qwen/qwen3.7-max": .answer("A4", usage: usage),
            ],
            synthesisScript: .answer(synthesis, usage: usage))

        let orchestrator = QuartetOrchestrator(resolver: FakeResolver(provider: provider))
        let (_, record) = try await drain(orchestrator.run(query: QuartetQuery(text: "Q"),
                                                           config: QuartetRunConfig(seats: seats())))

        let r = try XCTUnwrap(record)
        let truncated = try XCTUnwrap(r.seats.first { $0.modelID == "openai/gpt-5.6-sol-pro" })
        XCTAssertFalse(truncated.succeeded)
        XCTAssertEqual(truncated.text, "", "A truncated stream must not leave a half answer in the transcript")
    }

    func testBadDissentJSONFailsClosedNotConsensus() async throws {
        let usage = TokenUsage(inputTokens: 10, outputTokens: 5)
        let provider = FakeProvider(
            scripts: [
                "claude-opus-4-8": .answer("A1", usage: usage),
                "openai/gpt-5.6-sol-pro": .answer("A2", usage: usage),
                "google/gemini-3.1-pro-preview": .answer("A3", usage: usage),
                "qwen/qwen3.7-max": .answer("A4", usage: usage),
            ],
            synthesisScript: .answer("Answer with no marker at all", usage: usage))

        let orchestrator = QuartetOrchestrator(resolver: FakeResolver(provider: provider))
        let (_, record) = try await drain(orchestrator.run(query: QuartetQuery(text: "Q"),
                                                           config: QuartetRunConfig(seats: seats())))

        let r = try XCTUnwrap(record)
        guard case .extractionFailed = r.dissent else {
            return XCTFail("expected extractionFailed, got \(r.dissent)")
        }
        XCTAssertEqual(r.synthesizedAnswer, "Answer with no marker at all")
    }

    func testDeliberationRevisesAnswersAndAddsUsageLegs() async throws {
        let usage = TokenUsage(inputTokens: 10, outputTokens: 5)
        let synthesis = "Answer.\n===DISSENT===\n```json\n{\"dissents\": []}\n```"
        let provider = FakeProvider(
            scripts: [
                "claude-opus-4-8": .answer("R", usage: usage),
                "openai/gpt-5.6-sol-pro": .answer("R", usage: usage),
                "google/gemini-3.1-pro-preview": .answer("R", usage: usage),
                "qwen/qwen3.7-max": .answer("R", usage: usage),
            ],
            synthesisScript: .answer(synthesis, usage: usage))

        let orchestrator = QuartetOrchestrator(resolver: FakeResolver(provider: provider))
        let config = QuartetRunConfig(seats: seats(), deliberate: true)
        let (events, record) = try await drain(orchestrator.run(query: QuartetQuery(text: "Q"), config: config))

        let r = try XCTUnwrap(record)
        XCTAssertTrue(r.deliberate)
        XCTAssertTrue(events.contains { if case .seatRevised = $0 { return true }; return false })
        // Two legs per seat (round 1 + revision): usage doubles.
        let opus = try XCTUnwrap(r.seats.first { $0.modelID == "claude-opus-4-8" })
        XCTAssertEqual(opus.usage, TokenUsage(inputTokens: 20, outputTokens: 10))
    }

    func testInvalidSeatConfigThrows() async {
        let provider = FakeProvider(scripts: [:], synthesisScript: nil)
        let orchestrator = QuartetOrchestrator(resolver: FakeResolver(provider: provider))
        var threeSeats = seats()
        threeSeats.removeLast()
        do {
            _ = try await drain(orchestrator.run(query: QuartetQuery(text: "Q"),
                                                 config: QuartetRunConfig(seats: threeSeats)))
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? SeatConfigurationError, .wrongSeatCount(3))
        }
    }

    func testRunRecordCodableRoundTrip() async throws {
        let usage = TokenUsage(inputTokens: 10, outputTokens: 5)
        let synthesis = "Answer.\n===DISSENT===\n```json\n{\"dissents\": []}\n```"
        let provider = FakeProvider(
            scripts: [
                "claude-opus-4-8": .answer("A1", usage: usage),
                "openai/gpt-5.6-sol-pro": .answer("A2", usage: usage),
                "google/gemini-3.1-pro-preview": .answer("A3", usage: usage),
                "qwen/qwen3.7-max": .answer("A4", usage: usage),
            ],
            synthesisScript: .answer(synthesis, usage: usage))
        let orchestrator = QuartetOrchestrator(resolver: FakeResolver(provider: provider))
        let (_, record) = try await drain(orchestrator.run(query: QuartetQuery(text: "Q"),
                                                           config: QuartetRunConfig(seats: seats())))
        let r = try XCTUnwrap(record)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTripped = try decoder.decode(RunRecord.self, from: encoder.encode(r))
        // ISO8601 drops sub-second precision; compare everything except createdAt exactly.
        XCTAssertEqual(roundTripped.id, r.id)
        XCTAssertEqual(roundTripped.seats, r.seats)
        XCTAssertEqual(roundTripped.dissent, r.dissent)
        XCTAssertEqual(roundTripped.cost, r.cost)
        XCTAssertEqual(roundTripped.synthesizedAnswer, r.synthesizedAnswer)
    }
}
