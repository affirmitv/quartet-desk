import Foundation

/// Normalized streaming chunk emitted by every provider client.
public enum StreamChunk: Sendable, Equatable {
    case textDelta(String)
    /// Cumulative usage snapshot (providers may report input early and output late).
    case usage(TokenUsage)
    /// Terminal marker. A stream that ends without one MUST be treated as truncated.
    case completed(stopReason: String?)
}

/// Implemented by the Providers module. The engine only sees this protocol,
/// which keeps the orchestrator network-free and testable with fakes.
public protocol ProviderStreaming: Sendable {
    /// Streams a completion. The stream MUST finish(throwing:) if the underlying
    /// transport ends before a terminal `.completed` chunk (fail closed — never
    /// let a half answer look complete).
    func stream(request: SeatRequest, apiKey: String) -> AsyncThrowingStream<StreamChunk, Error>
}

/// Resolves clients and API keys for the orchestrator.
public protocol ProviderResolving: Sendable {
    func client(for seat: Seat) throws -> any ProviderStreaming
    func apiKey(for provider: ProviderKind) throws -> String
}

public enum ProviderError: Error, Equatable, Sendable, LocalizedError {
    case missingAPIKey(ProviderKind)
    case invalidResponse
    case http(status: Int, body: String)
    case api(message: String)
    case malformedEvent(String)
    case truncatedStream(provider: String)
    case emptyAnswer
    /// The per-call wall-clock deadline elapsed before the stream completed.
    case timedOut(afterSeconds: Double)

    /// Single source of truth for how much provider error body to display.
    /// (Capture size is StreamingHTTP.maxCapturedBodyBytes in QuartetProviders.)
    public static let maxDisplayedBodyChars = 400

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p):
            return "No API key stored for \(p.displayName). Add one in Settings."
        case .invalidResponse:
            return "The server returned a non-HTTP response."
        case .http(let status, let body):
            let trimmed = body.count > Self.maxDisplayedBodyChars
                ? String(body.prefix(Self.maxDisplayedBodyChars)) + "…"
                : body
            return "HTTP \(status): \(trimmed)"
        case .api(let message):
            return "API error: \(message)"
        case .malformedEvent(let detail):
            return "Malformed stream event: \(detail)"
        case .truncatedStream(let provider):
            return "\(provider) stream ended before completion — answer is incomplete and was discarded."
        case .emptyAnswer:
            return "Provider completed the stream but returned an empty answer."
        case .timedOut(let seconds):
            return String(format: "Call exceeded the %.0fs wall-clock limit and was cancelled.", seconds)
        }
    }
}
