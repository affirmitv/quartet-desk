import Foundation
import os

/// Everything a run needs besides the query itself.
public struct QuartetRunConfig: Sendable {
    public var seats: [Seat]
    public var deliberate: Bool
    public var maxTokensPerSeat: Int
    public var maxTokensSynthesis: Int
    public var priceTable: PriceTable
    /// Wall-clock ceiling per provider call (seat leg or synthesis). A stream
    /// that neither completes nor errors within this window is cancelled and
    /// the seat fails with ProviderError.timedOut — no run hangs forever.
    public var perCallWallClockSeconds: TimeInterval

    public init(seats: [Seat],
                deliberate: Bool = false,
                maxTokensPerSeat: Int = 8192,
                maxTokensSynthesis: Int = 16384,
                priceTable: PriceTable = .bundledDefault,
                perCallWallClockSeconds: TimeInterval = 600) {
        self.seats = seats
        self.deliberate = deliberate
        self.maxTokensPerSeat = maxTokensPerSeat
        self.maxTokensSynthesis = maxTokensSynthesis
        self.priceTable = priceTable
        self.perCallWallClockSeconds = perCallWallClockSeconds
    }
}

public struct QuartetQuery: Sendable {
    public var text: String
    public var images: [ImageAttachment]

    public init(text: String, images: [ImageAttachment] = []) {
        self.text = text
        self.images = images
    }
}

/// Live events emitted while a run progresses.
public enum QuartetEvent: Sendable {
    case seatBegan(seatID: UUID)
    case seatDelta(seatID: UUID, text: String)
    case seatUsage(seatID: UUID, usage: TokenUsage)
    case seatCompleted(seatID: UUID, text: String, usage: TokenUsage?)
    /// The seat's answer hit the provider token limit — text is kept but INCOMPLETE.
    case seatTruncated(seatID: UUID)
    case seatFailed(seatID: UUID, message: String)
    case seatRevisionBegan(seatID: UUID)
    case seatRevisionDelta(seatID: UUID, text: String)
    case seatRevised(seatID: UUID, text: String, usage: TokenUsage?)
    case seatRevisionFailed(seatID: UUID, message: String)
    case synthesisBegan
    case synthesisDelta(text: String)
    case synthesisFailed(message: String)
    /// Always the final event on a stream that didn't throw.
    case finished(RunRecord)
}

/// Runs the quartet pipeline: fan-out → (optional deliberation) → synthesis →
/// dissent parse → cost → RunRecord. UI-free; providers come in via protocol.
public struct QuartetOrchestrator: Sendable {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "orchestrator")

    private let resolver: any ProviderResolving

    public init(resolver: any ProviderResolving) {
        self.resolver = resolver
    }

    public func run(query: QuartetQuery, config: QuartetRunConfig) -> AsyncThrowingStream<QuartetEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<QuartetEvent, Error>.makeStream()
        let resolver = self.resolver
        let task = Task {
            do {
                try SeatConfiguration.validate(config.seats)
                let record = try await Self.execute(query: query,
                                                    config: config,
                                                    resolver: resolver,
                                                    continuation: continuation)
                continuation.yield(.finished(record))
                continuation.finish()
            } catch {
                Self.logger.error("Quartet run failed: \(redactedDescription(for: error), privacy: .public)")
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Pipeline

    private struct SeatOutcome: Sendable {
        var seat: Seat
        var text: String
        var legs: [UsageLeg]
        var errorMessage: String?
        var revisionFailed: Bool
        var truncated: Bool
    }

    /// Stop reasons that mean "the text was cut off at the token limit":
    /// Anthropic reports "max_tokens" (and "model_context_window_exceeded");
    /// OpenAI-compatible endpoints report "length".
    static func isTruncationStopReason(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return ["max_tokens", "length", "model_context_window_exceeded"].contains(reason)
    }

    private static func execute(query: QuartetQuery,
                                config: QuartetRunConfig,
                                resolver: any ProviderResolving,
                                continuation: AsyncThrowingStream<QuartetEvent, Error>.Continuation) async throws -> RunRecord {
        // ---- Round 1: fan out in parallel ----
        var outcomes: [UUID: SeatOutcome] = [:]
        await withTaskGroup(of: SeatOutcome.self) { group in
            for seat in config.seats {
                group.addTask {
                    await runSeatRound1(seat: seat, query: query, config: config,
                                        resolver: resolver, continuation: continuation)
                }
            }
            for await outcome in group {
                outcomes[outcome.seat.id] = outcome
            }
        }
        try Task.checkCancellation()

        // ---- Optional Round 2: deliberation ----
        if config.deliberate {
            let succeeded = config.seats.compactMap { seat -> SeatOutcome? in
                guard let o = outcomes[seat.id], o.errorMessage == nil else { return nil }
                return o
            }
            if succeeded.count >= 2 {
                var revised: [UUID: SeatOutcome] = [:]
                await withTaskGroup(of: SeatOutcome.self) { group in
                    for outcome in succeeded {
                        let others = succeeded
                            .filter { $0.seat.id != outcome.seat.id }
                            .map { PanelAnswer(seatName: $0.seat.name, modelID: $0.seat.modelID, text: $0.text) }
                        group.addTask {
                            await runSeatDeliberation(outcome: outcome, others: others, query: query,
                                                      config: config, resolver: resolver,
                                                      continuation: continuation)
                        }
                    }
                    for await outcome in group {
                        revised[outcome.seat.id] = outcome
                    }
                }
                for (id, outcome) in revised { outcomes[id] = outcome }
            } else {
                logger.warning("Deliberate skipped: fewer than 2 seats succeeded in round 1.")
            }
        }
        try Task.checkCancellation()

        // ---- Synthesis ----
        let orderedOutcomes = config.seats.compactMap { outcomes[$0.id] }
        let answers = orderedOutcomes
            .filter { $0.errorMessage == nil }
            .map { PanelAnswer(seatName: $0.seat.name, modelID: $0.seat.modelID, text: $0.text, truncated: $0.truncated) }
        let failures = orderedOutcomes
            .filter { $0.errorMessage != nil }
            .map { PanelFailure(seatName: $0.seat.name, modelID: $0.seat.modelID, reason: $0.errorMessage ?? "unknown") }

        // Force-unwrap safe: SeatConfiguration.validate guarantees exactly one anchor.
        let anchor = config.seats.first(where: \.isAnchor)!

        var synthesizedAnswer: String?
        var synthesisRaw: String?
        var synthesisUsage: TokenUsage?
        var synthesisError: String?
        var synthesisTruncated = false
        var dissent: DissentOutcome = .notRun

        if outcomes[anchor.id]?.errorMessage != nil {
            synthesisError = "Anchor seat failed in the panel round — no synthesized answer. See PANEL tab."
            continuation.yield(.synthesisFailed(message: synthesisError!))
        } else if answers.isEmpty {
            synthesisError = "No seat produced an answer — nothing to synthesize."
            continuation.yield(.synthesisFailed(message: synthesisError!))
        } else {
            continuation.yield(.synthesisBegan)
            let messages = [
                ChatMessage(role: .system, text: PromptAssembly.synthesisSystemPrompt()),
                ChatMessage(role: .user,
                            text: PromptAssembly.synthesisUserPrompt(query: query.text, answers: answers, failures: failures)),
            ]
            let request = SeatRequest(seat: anchor, messages: messages, maxTokens: config.maxTokensSynthesis)
            do {
                let result = try await collectStream(request: request,
                                                     resolver: resolver,
                                                     timeout: config.perCallWallClockSeconds) { delta in
                    continuation.yield(.synthesisDelta(text: delta))
                }
                synthesisRaw = result.text
                synthesisUsage = result.usage
                synthesisTruncated = isTruncationStopReason(result.stopReason)
                if synthesisTruncated {
                    logger.warning("Synthesis hit the token limit (stop=\(result.stopReason ?? "?", privacy: .public)) — flagged as truncated")
                }
                let parsed = DissentParser.parse(synthesisOutput: result.text)
                synthesizedAnswer = parsed.answer
                dissent = parsed.outcome
            } catch {
                synthesisError = userFacingMessage(for: error)
                logger.error("Synthesis failed: \(redactedDescription(for: error), privacy: .public)")
                continuation.yield(.synthesisFailed(message: synthesisError!))
            }
        }

        // ---- Cost ----
        var legs = orderedOutcomes.flatMap(\.legs)
        if let synthesisUsage {
            legs.append(UsageLeg(modelID: anchor.modelID, usage: synthesisUsage))
        }
        let cost = CostCalculator.cost(legs: legs, table: config.priceTable)

        // ---- Record ----
        let transcripts = orderedOutcomes.map { outcome in
            SeatTranscript(id: outcome.seat.id,
                           seatName: outcome.seat.name,
                           provider: outcome.seat.provider,
                           modelID: outcome.seat.modelID,
                           isAnchor: outcome.seat.isAnchor,
                           text: outcome.text,
                           usage: outcome.legs.isEmpty ? nil : outcome.legs.map(\.usage).reduce(TokenUsage(inputTokens: 0, outputTokens: 0), +),
                           errorMessage: outcome.errorMessage,
                           revisionFailed: outcome.revisionFailed,
                           truncated: outcome.truncated)
        }

        return RunRecord(id: UUID(),
                         createdAt: Date(),
                         queryText: query.text,
                         imageCount: query.images.count,
                         deliberate: config.deliberate,
                         seats: transcripts,
                         synthesizedAnswer: synthesizedAnswer,
                         synthesisRaw: synthesisRaw,
                         synthesisUsage: synthesisUsage,
                         synthesisError: synthesisError,
                         synthesisTruncated: synthesisTruncated,
                         dissent: dissent,
                         cost: cost)
    }

    // MARK: - Seat helpers

    private static func runSeatRound1(seat: Seat,
                                      query: QuartetQuery,
                                      config: QuartetRunConfig,
                                      resolver: any ProviderResolving,
                                      continuation: AsyncThrowingStream<QuartetEvent, Error>.Continuation) async -> SeatOutcome {
        continuation.yield(.seatBegan(seatID: seat.id))
        let messages = [
            ChatMessage(role: .system, text: PromptAssembly.panelistSystemPrompt()),
            ChatMessage(role: .user, text: query.text, images: query.images),
        ]
        let request = SeatRequest(seat: seat, messages: messages, maxTokens: config.maxTokensPerSeat)
        do {
            let result = try await collectStream(request: request,
                                                 resolver: resolver,
                                                 timeout: config.perCallWallClockSeconds) { delta in
                continuation.yield(.seatDelta(seatID: seat.id, text: delta))
            } onUsage: { usage in
                continuation.yield(.seatUsage(seatID: seat.id, usage: usage))
            }
            continuation.yield(.seatCompleted(seatID: seat.id, text: result.text, usage: result.usage))
            let truncated = isTruncationStopReason(result.stopReason)
            if truncated {
                logger.warning("Seat \(seat.name, privacy: .public) hit the token limit (stop=\(result.stopReason ?? "?", privacy: .public)) — flagged as truncated")
                continuation.yield(.seatTruncated(seatID: seat.id))
            }
            let legs = result.usage.map { [UsageLeg(modelID: seat.modelID, usage: $0)] } ?? []
            return SeatOutcome(seat: seat, text: result.text, legs: legs,
                               errorMessage: nil, revisionFailed: false, truncated: truncated)
        } catch {
            let message = userFacingMessage(for: error)
            logger.error("Seat \(seat.name, privacy: .public) failed: \(redactedDescription(for: error), privacy: .public)")
            continuation.yield(.seatFailed(seatID: seat.id, message: message))
            return SeatOutcome(seat: seat, text: "", legs: [],
                               errorMessage: message, revisionFailed: false, truncated: false)
        }
    }

    private static func runSeatDeliberation(outcome: SeatOutcome,
                                            others: [PanelAnswer],
                                            query: QuartetQuery,
                                            config: QuartetRunConfig,
                                            resolver: any ProviderResolving,
                                            continuation: AsyncThrowingStream<QuartetEvent, Error>.Continuation) async -> SeatOutcome {
        let seat = outcome.seat
        continuation.yield(.seatRevisionBegan(seatID: seat.id))
        let messages = [
            ChatMessage(role: .system, text: PromptAssembly.panelistSystemPrompt()),
            ChatMessage(role: .user,
                        text: PromptAssembly.deliberationUserPrompt(query: query.text, ownAnswer: outcome.text, others: others),
                        images: query.images),
        ]
        let request = SeatRequest(seat: seat, messages: messages, maxTokens: config.maxTokensPerSeat)
        do {
            let result = try await collectStream(request: request,
                                                 resolver: resolver,
                                                 timeout: config.perCallWallClockSeconds) { delta in
                continuation.yield(.seatRevisionDelta(seatID: seat.id, text: delta))
            } onUsage: { usage in
                continuation.yield(.seatUsage(seatID: seat.id, usage: usage))
            }
            continuation.yield(.seatRevised(seatID: seat.id, text: result.text, usage: result.usage))
            var revised = outcome
            revised.text = result.text
            // The revision REPLACES the text, so its stop reason replaces the flag.
            revised.truncated = isTruncationStopReason(result.stopReason)
            if revised.truncated {
                logger.warning("Deliberation for seat \(seat.name, privacy: .public) hit the token limit — flagged as truncated")
                continuation.yield(.seatTruncated(seatID: seat.id))
            }
            if let usage = result.usage {
                revised.legs.append(UsageLeg(modelID: seat.modelID, usage: usage))
            }
            return revised
        } catch {
            // Fail-soft for revisions only: the seat KEEPS its round-1 answer,
            // and the failure is surfaced (event + transcript flag) — never hidden.
            let message = userFacingMessage(for: error)
            logger.error("Deliberation for seat \(seat.name, privacy: .public) failed; keeping round-1 answer: \(redactedDescription(for: error), privacy: .public)")
            continuation.yield(.seatRevisionFailed(seatID: seat.id, message: message))
            var kept = outcome
            kept.revisionFailed = true
            return kept
        }
    }

    private struct CollectedResult: Sendable {
        var text: String
        var usage: TokenUsage?
        var stopReason: String?
    }

    /// Drains a provider stream into a full answer under a wall-clock deadline.
    /// Throws on transport/provider errors, on missing terminal chunk (the
    /// client throws truncatedStream), on an empty final answer, and on
    /// exceeding `timeout` (ProviderError.timedOut — no seat can hang a run
    /// forever; the losing branch is cancelled either way).
    private static func collectStream(request: SeatRequest,
                                      resolver: any ProviderResolving,
                                      timeout: TimeInterval,
                                      onDelta: @escaping @Sendable (String) -> Void,
                                      onUsage: @escaping @Sendable (TokenUsage) -> Void = { _ in }) async throws -> CollectedResult {
        // `perCallWallClockSeconds` is a public config knob — validate it before
        // the nanosecond conversion. A NaN, negative, or overflowing Double →
        // UInt64 conversion TRAPS; a bad config must instead surface as a
        // controlled per-seat failure.
        guard timeout.isFinite, timeout > 0 else {
            throw ProviderError.api(message: "Invalid per-call timeout (\(timeout)s) — perCallWallClockSeconds must be a positive, finite number of seconds.")
        }
        // Ceiling keeps timeout * 1e9 far away from UInt64.max. 7 days is
        // already absurd for a single provider call; documented, not silent.
        let cappedTimeout = min(timeout, 7 * 86_400)
        return try await withThrowingTaskGroup(of: CollectedResult.self) { group in
            group.addTask {
                try await drainStream(request: request, resolver: resolver,
                                      onDelta: onDelta, onUsage: onUsage)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(cappedTimeout * 1_000_000_000))
                throw ProviderError.timedOut(afterSeconds: cappedTimeout)
            }
            // First child to finish wins: either the drained result, or the
            // deadline throwing timedOut. Cancel the loser.
            guard let result = try await group.next() else {
                throw ProviderError.invalidResponse // unreachable: group is never empty
            }
            group.cancelAll()
            return result
        }
    }

    private static func drainStream(request: SeatRequest,
                                    resolver: any ProviderResolving,
                                    onDelta: @Sendable (String) -> Void,
                                    onUsage: @Sendable (TokenUsage) -> Void) async throws -> CollectedResult {
        let client = try resolver.client(for: request.seat)
        let apiKey = try resolver.apiKey(for: request.seat.provider)
        var text = ""
        var usage: TokenUsage?
        var stopReason: String?
        var completed = false
        for try await chunk in client.stream(request: request, apiKey: apiKey) {
            // Explicit cancellation check per chunk: when the deadline child
            // wins the race and cancelAll() fires, no further deltas may reach
            // the continuation — a wedged provider drip-feeding bytes must not
            // keep painting a seat that has already been declared timed out.
            try Task.checkCancellation()
            switch chunk {
            case .textDelta(let delta):
                text += delta
                onDelta(delta)
            case .usage(let update):
                usage = update
                onUsage(update)
            case .completed(let reason):
                stopReason = reason
                completed = true
            }
        }
        guard completed else {
            // Belt and braces: clients throw before we get here, but never trust that.
            // Also the path taken when the deadline task cancelled this drain.
            try Task.checkCancellation()
            throw ProviderError.truncatedStream(provider: request.seat.provider.displayName)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.emptyAnswer
        }
        return CollectedResult(text: text, usage: usage, stopReason: stopReason)
    }
}
