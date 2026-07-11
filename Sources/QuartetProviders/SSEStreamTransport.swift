import Foundation
import os
import QuartetEngine

/// Single shared streaming transport for every SSE provider. Owns the request
/// loop, HTTP validation, SSE parsing, the retry policy, EOF-truncation
/// diagnostics, and termination handling — clients supply only a request
/// builder and a decoder. (Previously this ~30-line loop was copy-pasted per
/// client, which is exactly where retry/backoff would have had to be
/// implemented twice and kept in sync forever.)
struct SSEStreamTransport: Sendable {
    let providerName: String
    let logger: Logger
    var session: URLSession = .shared
    var retryPolicy: StreamRetryPolicy = StreamRetryPolicy()

    /// Streams a completion, retrying transient pre-data failures per
    /// `StreamRetryPolicy` (never after the first chunk has been yielded —
    /// retrying a partially-delivered answer would duplicate text downstream).
    func stream(makeRequest: @escaping @Sendable () throws -> URLRequest,
                makeDecoder: @escaping @Sendable () -> any SSEChunkDecoder) -> AsyncThrowingStream<StreamChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<StreamChunk, Error>.makeStream()
        let task = Task {
            var attempt = 1
            var yieldedAnyChunk = false
            while true {
                do {
                    try await runAttempt(makeRequest: makeRequest,
                                         makeDecoder: makeDecoder,
                                         yieldedAnyChunk: &yieldedAnyChunk,
                                         continuation: continuation)
                    continuation.finish()
                    return
                } catch let attemptError {
                    let kind = Self.classify(attemptError)
                    let decision = retryPolicy.decision(for: kind,
                                                        attempt: attempt,
                                                        hasYieldedChunks: yieldedAnyChunk)
                    switch decision {
                    case .retry(let delay):
                        // NOT silent: every retry is logged with attempt count.
                        logger.warning("\(self.providerName, privacy: .public) attempt \(attempt)/\(self.retryPolicy.maxAttempts) failed (\(String(describing: kind), privacy: .public)) — retrying in \(String(format: "%.2f", delay), privacy: .public)s")
                        do {
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        } catch {
                            // Cancelled during backoff — surface the ORIGINAL
                            // attempt failure, not the sleep's CancellationError
                            // (which the unlabeled inner `catch` used to shadow
                            // it with).
                            continuation.finish(throwing: Self.normalize(attemptError, providerName: providerName))
                            return
                        }
                        attempt += 1
                    case .fail:
                        logger.error("\(self.providerName, privacy: .public) stream failed (attempt \(attempt)): \(String(describing: attemptError), privacy: .public)")
                        continuation.finish(throwing: Self.normalize(attemptError, providerName: providerName))
                        return
                    }
                }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runAttempt(makeRequest: @Sendable () throws -> URLRequest,
                            makeDecoder: @Sendable () -> any SSEChunkDecoder,
                            yieldedAnyChunk: inout Bool,
                            continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation) async throws {
        let urlRequest = try makeRequest()
        let (bytes, response) = try await session.bytes(for: urlRequest)
        try await StreamingHTTP.validate(bytes: bytes, response: response, logger: logger)

        var splitter = SSELineSplitter()
        var parser = SSEParser()
        var decoder = makeDecoder()

        for try await byte in bytes {
            // Cooperative cancellation per byte (a cheap flag read): when the
            // consumer tears down (onTermination → task.cancel()), a provider
            // drip-feeding bytes must not keep this attempt alive.
            try Task.checkCancellation()
            guard let line = splitter.feed(byte) else { continue }
            guard let event = parser.feed(line: line) else { continue }
            for chunk in try decoder.decode(event) {
                yieldedAnyChunk = true
                continuation.yield(chunk)
            }
            if decoder.sawTerminal { break }
        }

        guard decoder.sawTerminal else {
            // Fail closed on EOF-without-terminal, and log what was left in the
            // pipe (half line / undispatched fields) — the truncation diagnostics
            // SSELineSplitter.flushRemainder and SSEParser.hasPendingFields exist for.
            if let tail = splitter.flushRemainder(), !tail.isEmpty {
                logger.error("\(self.providerName, privacy: .public) stream truncated with a half-line tail: \(SecretRedactor.redact(String(tail.prefix(200))), privacy: .public)")
            } else if parser.hasPendingFields {
                logger.error("\(self.providerName, privacy: .public) stream truncated mid-event (undispatched SSE fields at EOF)")
            }
            throw ProviderError.truncatedStream(provider: providerName)
        }
    }

    /// Maps a thrown error onto the pure retry policy's failure taxonomy.
    static func classify(_ error: Error) -> StreamRetryPolicy.FailureKind {
        if let failure = error as? StreamingHTTP.HTTPFailure {
            return .http(status: failure.status, retryAfter: failure.retryAfter)
        }
        if let providerError = error as? ProviderError {
            switch providerError {
            case .truncatedStream:
                return .truncatedBeforeTerminal
            case .http(let status, _):
                return .http(status: status, retryAfter: nil)
            default:
                return .other
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .dnsLookupFailed, .notConnectedToInternet:
                return .transientTransport
            default:
                return .other
            }
        }
        return .other
    }

    /// Internal transport errors never escape to consumers — they become the
    /// public ProviderError with the parsed (clean, redacted) message.
    static func normalize(_ error: Error, providerName: String) -> Error {
        if let failure = error as? StreamingHTTP.HTTPFailure {
            return ProviderError.http(status: failure.status, body: failure.message)
        }
        return error
    }
}

/// Shared HTTP status validation for streaming responses.
enum StreamingHTTP {
    /// Single source of truth for how much provider error body to capture.
    /// (Display truncation is ProviderError.maxDisplayedBodyChars.)
    static let maxCapturedBodyBytes = 16_384

    /// Internal failure carrying everything the retry policy needs. Converted
    /// to ProviderError.http before it reaches a consumer.
    struct HTTPFailure: Error {
        let status: Int
        /// Parsed provider error message when the body is a standard error
        /// envelope, else the (redacted, truncated) raw body — so a 429 renders
        /// like a mid-stream API error instead of dumping raw JSON at the user.
        let message: String
        let retryAfter: TimeInterval?
    }

    /// Throws HTTPFailure with a parsed+redacted message on non-2xx.
    static func validate(bytes: URLSession.AsyncBytes, response: URLResponse, logger: Logger) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= maxCapturedBodyBytes { break }
                }
            } catch {
                logger.error("Failed reading error body for HTTP \(http.statusCode): \(String(describing: error), privacy: .public)")
            }
            let raw = String(decoding: body, as: UTF8.self)
            let message = SecretRedactor.redact(parseErrorEnvelope(raw) ?? raw)
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(parseRetryAfter)
            throw HTTPFailure(status: http.statusCode, message: message, retryAfter: retryAfter)
        }
    }

    /// Both Anthropic and OpenAI-compatible endpoints wrap errors as
    /// {"error": {"type": ..., "message": ...}} — extract the human message so
    /// pre-stream HTTP errors render as cleanly as mid-stream API errors.
    static func parseErrorEnvelope(_ body: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty else {
            return nil
        }
        if let type = error["type"] as? String, !type.isEmpty {
            return "\(type): \(message)"
        }
        return message
    }

    /// Retry-After is either delta-seconds or an HTTP-date.
    static func parseRetryAfter(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: trimmed) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}
