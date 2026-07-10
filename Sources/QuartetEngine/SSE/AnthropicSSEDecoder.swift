import Foundation

/// Decodes Anthropic Messages API SSE events into normalized `StreamChunk`s.
///
/// Event types handled (per the Messages API streaming contract):
/// - `message_start`        → initial usage (input_tokens)
/// - `content_block_delta`  → `text_delta` text (thinking/other deltas ignored)
/// - `message_delta`        → final output_tokens + stop_reason
/// - `message_stop`         → terminal marker
/// - `error`                → thrown
/// - `ping`, `content_block_start`, `content_block_stop` → ignored
///
/// Fail-closed: `sawTerminal` stays false until `message_stop`; the transport
/// wrapper must treat EOF-without-terminal as a truncated stream.
public struct AnthropicSSEDecoder: Sendable {
    public private(set) var sawTerminal = false
    public private(set) var stopReason: String?

    private var inputTokens = 0
    private var outputTokens = 0

    public init() {}

    public mutating func decode(_ event: SSEEvent) throws -> [StreamChunk] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
              let type = object["type"] as? String else {
            throw ProviderError.malformedEvent("Anthropic event is not a JSON object with a type: \(event.data.prefix(200))")
        }

        switch type {
        case "message_start":
            guard let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return [] }
            inputTokens = usage["input_tokens"] as? Int ?? 0
            outputTokens = usage["output_tokens"] as? Int ?? 0
            return [.usage(TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens))]

        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return [] }
            if deltaType == "text_delta", let text = delta["text"] as? String {
                return [.textDelta(text)]
            }
            return [] // thinking_delta / input_json_delta etc. — not part of the answer text

        case "message_delta":
            var chunks: [StreamChunk] = []
            if let usage = object["usage"] as? [String: Any],
               let output = usage["output_tokens"] as? Int {
                outputTokens = output
                chunks.append(.usage(TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)))
            }
            if let delta = object["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
            return chunks

        case "message_stop":
            sawTerminal = true
            return [.completed(stopReason: stopReason)]

        case "error":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "unknown Anthropic API error"
            throw ProviderError.api(message: message)

        case "ping", "content_block_start", "content_block_stop":
            return []

        default:
            return [] // unknown event types are tolerated for forward compatibility
        }
    }
}
