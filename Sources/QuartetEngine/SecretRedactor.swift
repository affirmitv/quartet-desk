import Foundation

/// BEST-EFFORT defense-in-depth masking of credential-shaped substrings before
/// text is persisted (run history, exports), logged, or displayed.
///
/// This is NOT a guarantee and must never be the sole barrier: pattern matching
/// can only catch known credential shapes, so callers that handle content-
/// bearing payloads (crash reports, error envelopes) must additionally DROP
/// those fields at the source (see CrashReportingBootstrap.scrub) rather than
/// rely on redaction alone. What this buys: a provider or proxy that echoes a
/// request's own key back in an error body won't get that key written verbatim
/// into a history file or log line for the shapes below.
public enum SecretRedactor {
    private static let patterns: [String] = [
        // OpenAI/Anthropic/OpenRouter style keys: sk-..., sk-ant-..., sk-or-v1-...
        #"sk-[A-Za-z0-9_\-]{8,}"#,
        // Google-style API keys (relevant when a seat routes to Gemini): AIza...
        #"AIza[A-Za-z0-9_\-]{16,}"#,
        // JWTs (session tokens): three dot-separated base64url segments.
        #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        // Bearer tokens in echoed headers/bodies
        #"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"#,
        // Echoed x-api-key header values
        #"(?i)x-api-key['":\s]+[A-Za-z0-9._\-]{16,}"#,
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern,
                                                 with: "[REDACTED]",
                                                 options: .regularExpression)
        }
        return result
    }
}
