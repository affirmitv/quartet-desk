import Foundation
import os
import QuartetEngine

/// Direct client for the Anthropic Messages API (`POST /v1/messages`, streaming SSE).
public struct AnthropicClient: ProviderStreaming {
    static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "anthropic")
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    public init() {}

    public func stream(request: SeatRequest, apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
        SSEStreamTransport(providerName: "Anthropic", logger: Self.logger)
            .stream(makeRequest: { try Self.makeURLRequest(request: request, apiKey: apiKey) },
                    makeDecoder: { AnthropicSSEDecoder() })
    }

    // MARK: - Request building

    struct RequestBody: Encodable {
        var model: String
        var max_tokens: Int
        var stream: Bool
        var system: String?
        var messages: [Message]
        /// Set per-model by `makeURLRequest` (see `supportsAdaptiveThinking`).
        /// nil ⇒ the field is omitted from the wire body entirely — the one
        /// shape that is valid on EVERY Claude model.
        var thinking: Thinking?

        struct Thinking: Encodable {
            var type: String
        }

        struct Message: Encodable {
            var role: String
            var content: [Content]
        }

        enum Content: Encodable {
            case text(String)
            case image(mediaType: String, base64: String)

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: DynamicKey.self)
                switch self {
                case .text(let text):
                    try container.encode("text", forKey: DynamicKey("type"))
                    try container.encode(text, forKey: DynamicKey("text"))
                case .image(let mediaType, let base64):
                    try container.encode("image", forKey: DynamicKey("type"))
                    var source = container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("source"))
                    try source.encode("base64", forKey: DynamicKey("type"))
                    try source.encode(mediaType, forKey: DynamicKey("media_type"))
                    try source.encode(base64, forKey: DynamicKey("data"))
                }
            }
        }
    }

    /// Capability gate for `thinking: {"type": "adaptive"}`.
    ///
    /// Per the Anthropic Messages API docs (2026): adaptive thinking is the
    /// recommended mode on Opus 4.6+ / Sonnet 4.6 / Fable 5 — and the ONLY
    /// on-mode on Opus 4.7+ and Fable 5 (`budget_tokens` 400s there). Older
    /// models (Sonnet 4.5, Haiku 4.5, Opus 4.5/4.1, Claude 3.x) REJECT
    /// `type: "adaptive"` with a 400. Seats are user-configurable, so the
    /// param is sent only for known-supporting models; for anything else —
    /// including unknown future IDs — `thinking` is OMITTED, which is valid on
    /// every model (thinking simply stays off). No request can 400 on this
    /// field. Verified live 2026-07-10 (`swift run LiveSmoke`, claude-opus-4-8).
    static func supportsAdaptiveThinking(modelID: String) -> Bool {
        let adaptivePrefixes = [
            "claude-opus-4-6",
            "claude-opus-4-7",
            "claude-opus-4-8",
            "claude-sonnet-4-6",
            "claude-fable-5",
        ]
        return adaptivePrefixes.contains { modelID.hasPrefix($0) }
    }

    static func makeURLRequest(request: SeatRequest, apiKey: String) throws -> URLRequest {
        // Anthropic takes system prompts as a top-level field, not a message role.
        let systemText = request.messages
            .filter { $0.role == .system }
            .map(\.text)
            .joined(separator: "\n\n")

        let wireMessages: [RequestBody.Message] = request.messages
            .filter { $0.role != .system }
            .map { message in
                var content: [RequestBody.Content] = []
                for image in message.images {
                    content.append(.image(mediaType: image.mediaType, base64: image.base64Data))
                }
                content.append(.text(message.text))
                return RequestBody.Message(role: message.role.rawValue, content: content)
            }

        // Adaptive thinking where the model supports it (thinking tokens bill
        // as output tokens, so usage/cost accounting is unchanged; the decoder
        // already ignores thinking_delta frames). Omitted otherwise — never an
        // unconditional param a user-configured older model would 400 on.
        let body = RequestBody(model: request.seat.modelID,
                               max_tokens: request.maxTokens,
                               stream: true,
                               system: systemText.isEmpty ? nil : systemText,
                               messages: wireMessages,
                               thinking: supportsAdaptiveThinking(modelID: request.seat.modelID)
                                   ? RequestBody.Thinking(type: "adaptive")
                                   : nil)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120 // idle timeout between bytes, not total duration
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }
}

/// Minimal string-keyed CodingKey for hand-rolled wire shapes.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
