import Foundation

/// Single home for the "best human-readable message for this error" idiom.
/// Prefers LocalizedError's description, falls back to the debug description.
///
/// ALWAYS redacted: this is the choke point through which provider errors reach
/// persisted RunRecords, the UI, and exports. HTTP error bodies are already
/// redacted at capture (StreamingHTTP.validate), but mid-stream
/// `ProviderError.api(message:)` payloads, malformed-event echoes, and fallback
/// debug descriptions arrive here unredacted — a provider/proxy echoing a key
/// must not be able to write it into history via this path.
public func userFacingMessage(for error: Error) -> String {
    if let localized = (error as? LocalizedError)?.errorDescription {
        return SecretRedactor.redact(localized)
    }
    return SecretRedactor.redact(String(describing: error))
}

/// Redacted variant of `String(describing: error)` for log lines. Use this —
/// never the raw idiom — when logging errors that may carry provider payloads.
public func redactedDescription(for error: Error) -> String {
    SecretRedactor.redact(String(describing: error))
}
