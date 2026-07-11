import Foundation

/// Pure retry-decision logic for streaming provider calls. The transport layer
/// classifies its failures into `FailureKind` and asks this policy what to do;
/// keeping the decision pure makes every branch unit-testable without a network.
///
/// Invariants:
/// - NEVER retries after the first chunk has been yielded downstream — retrying
///   a partially-delivered answer would duplicate text in the UI.
/// - Only transient failures retry: retryable HTTP statuses (429/5xx/529),
///   truncation before any data, and transient transport errors.
/// - Backoff is exponential with jitter, bounded by `maxDelay`; a provider
///   `Retry-After` header is honored when present (also bounded).
public struct StreamRetryPolicy: Sendable, Equatable {
    /// Total attempts including the first (3 = 1 initial + 2 retries).
    public var maxAttempts: Int
    /// Anthropic documents 429 (rate_limit), 500 (api_error) and 529
    /// (overloaded) as retryable; 502/503 cover transient gateways.
    public var retryableStatuses: Set<Int>
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 3,
                retryableStatuses: Set<Int> = [429, 500, 502, 503, 529],
                baseDelay: TimeInterval = 1.0,
                maxDelay: TimeInterval = 30.0) {
        self.maxAttempts = maxAttempts
        self.retryableStatuses = retryableStatuses
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// How the attempt failed, as classified by the transport.
    public enum FailureKind: Sendable, Equatable {
        /// Non-2xx response. `retryAfter` is the parsed Retry-After header, if any.
        case http(status: Int, retryAfter: TimeInterval?)
        /// Transport EOF before the provider's terminal marker.
        case truncatedBeforeTerminal
        /// Transient network failure (timed out, connection lost, ...).
        case transientTransport
        /// Anything else (API errors, decode errors, auth failures) — never retried.
        case other
    }

    public enum Decision: Sendable, Equatable {
        case retry(after: TimeInterval)
        case fail
    }

    /// - Parameters:
    ///   - attempt: 1-based index of the attempt that just failed.
    ///   - hasYieldedChunks: whether ANY chunk already reached the consumer.
    ///   - jitter: unit-interval random component; injectable for deterministic tests.
    public func decision(for kind: FailureKind,
                         attempt: Int,
                         hasYieldedChunks: Bool,
                         jitter: Double = Double.random(in: 0..<1)) -> Decision {
        guard !hasYieldedChunks else { return .fail }
        guard attempt < maxAttempts else { return .fail }
        switch kind {
        case .http(let status, let retryAfter):
            guard retryableStatuses.contains(status) else { return .fail }
            if let retryAfter {
                return .retry(after: min(max(retryAfter, 0), maxDelay))
            }
            return .retry(after: backoffDelay(afterAttempt: attempt, jitter: jitter))
        case .truncatedBeforeTerminal, .transientTransport:
            return .retry(after: backoffDelay(afterAttempt: attempt, jitter: jitter))
        case .other:
            return .fail
        }
    }

    /// min(base * 2^(attempt-1) + jitter, maxDelay)
    func backoffDelay(afterAttempt attempt: Int, jitter: Double) -> TimeInterval {
        let exponential = baseDelay * pow(2, Double(max(attempt, 1) - 1))
        return min(exponential + jitter, maxDelay)
    }
}
