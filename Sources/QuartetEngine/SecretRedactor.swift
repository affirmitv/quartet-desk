import Foundation

/// Defense-in-depth masking of credential-shaped substrings before text is
/// persisted (run history, exports) or displayed. No provider currently echoes
/// keys in error bodies — this guards against a future provider or proxy that
/// does, so key material can never land in a history file.
public enum SecretRedactor {
    private static let patterns: [String] = [
        // OpenAI/Anthropic/OpenRouter style keys: sk-..., sk-ant-..., sk-or-v1-...
        #"sk-[A-Za-z0-9_\-]{8,}"#,
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
