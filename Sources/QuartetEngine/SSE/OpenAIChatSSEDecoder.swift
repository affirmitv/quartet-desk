import Foundation

/// Decodes OpenAI chat-completions-style SSE chunks (used by both OpenAI and
/// OpenRouter) into normalized `StreamChunk`s.
///
/// Wire shape:
/// - `data: {"choices":[{"delta":{"content":"..."},"finish_reason":null}], ...}`
/// - a usage chunk (with empty choices) when `stream_options.include_usage` is set
/// - `data: [DONE]` terminal marker
/// - `data: {"error": {...}}` mid-stream errors (OpenRouter does this)
///
/// Fail-closed: `sawTerminal` stays false until `[DONE]`.
public struct OpenAIChatSSEDecoder: Sendable {
    public private(set) var sawTerminal = false
    public private(set) var finishReason: String?

    public init() {}

    public mutating func decode(_ event: SSEEvent) throws -> [StreamChunk] {
        let payload = event.data.trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            sawTerminal = true
            return [.completed(stopReason: finishReason)]
        }

        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw ProviderError.malformedEvent("OpenAI-compatible chunk is not a JSON object: \(payload.prefix(200))")
        }

        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown provider error"
            throw ProviderError.api(message: message)
        }

        var chunks: [StreamChunk] = []

        if let usage = object["usage"] as? [String: Any],
           let prompt = usage["prompt_tokens"] as? Int,
           let completion = usage["completion_tokens"] as? Int {
            chunks.append(.usage(TokenUsage(inputTokens: prompt, outputTokens: completion)))
        }

        if let choices = object["choices"] as? [[String: Any]], let first = choices.first {
            if let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String,
               !content.isEmpty {
                chunks.append(.textDelta(content))
            }
            if let reason = first["finish_reason"] as? String {
                finishReason = reason
            }
        }

        return chunks
    }
}
