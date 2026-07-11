import XCTest
@testable import QuartetEngine

final class RetryPolicyTests: XCTestCase {
    private let policy = StreamRetryPolicy(maxAttempts: 3, baseDelay: 1.0, maxDelay: 30.0)

    func testRetryableStatusesRetryBeforeFirstByte() {
        for status in [429, 500, 502, 503, 529] {
            let decision = policy.decision(for: .http(status: status, retryAfter: nil),
                                           attempt: 1, hasYieldedChunks: false, jitter: 0)
            XCTAssertEqual(decision, .retry(after: 1.0), "HTTP \(status) must retry")
        }
    }

    func testNonRetryableStatusesFail() {
        for status in [400, 401, 403, 404, 413] {
            let decision = policy.decision(for: .http(status: status, retryAfter: nil),
                                           attempt: 1, hasYieldedChunks: false, jitter: 0)
            XCTAssertEqual(decision, .fail, "HTTP \(status) must NOT retry")
        }
    }

    func testNeverRetriesAfterFirstYieldedChunk() {
        // Retrying after data reached the consumer would duplicate partial answers.
        let decision = policy.decision(for: .http(status: 429, retryAfter: 1),
                                       attempt: 1, hasYieldedChunks: true, jitter: 0)
        XCTAssertEqual(decision, .fail)
    }

    func testFailsAfterMaxAttempts() {
        let decision = policy.decision(for: .http(status: 429, retryAfter: nil),
                                       attempt: 3, hasYieldedChunks: false, jitter: 0)
        XCTAssertEqual(decision, .fail)
    }

    func testHonorsRetryAfterHeader() {
        let decision = policy.decision(for: .http(status: 429, retryAfter: 7),
                                       attempt: 1, hasYieldedChunks: false, jitter: 0)
        XCTAssertEqual(decision, .retry(after: 7))
    }

    func testRetryAfterIsBoundedByMaxDelay() {
        let decision = policy.decision(for: .http(status: 429, retryAfter: 3600),
                                       attempt: 1, hasYieldedChunks: false, jitter: 0)
        XCTAssertEqual(decision, .retry(after: 30))
    }

    func testBackoffEscalatesAndIsBounded() {
        // attempt 1 -> 1s, attempt 2 -> 2s (base * 2^(n-1)), always <= maxDelay
        XCTAssertEqual(policy.backoffDelay(afterAttempt: 1, jitter: 0), 1.0)
        XCTAssertEqual(policy.backoffDelay(afterAttempt: 2, jitter: 0), 2.0)
        XCTAssertEqual(policy.backoffDelay(afterAttempt: 10, jitter: 0.9), 30.0)
    }

    func testJitterIsAdded() {
        XCTAssertEqual(policy.backoffDelay(afterAttempt: 1, jitter: 0.5), 1.5)
    }

    func testTruncationBeforeTerminalRetries() {
        let decision = policy.decision(for: .truncatedBeforeTerminal,
                                       attempt: 1, hasYieldedChunks: false, jitter: 0)
        XCTAssertEqual(decision, .retry(after: 1.0))
    }

    func testTransientTransportRetries() {
        let decision = policy.decision(for: .transientTransport,
                                       attempt: 2, hasYieldedChunks: false, jitter: 0)
        XCTAssertEqual(decision, .retry(after: 2.0))
    }

    func testOtherErrorsNeverRetry() {
        let decision = policy.decision(for: .other,
                                       attempt: 1, hasYieldedChunks: false, jitter: 0)
        XCTAssertEqual(decision, .fail)
    }
}

final class SecretRedactorTests: XCTestCase {
    func testRedactsAPIKeyShapes() {
        let body = #"{"error":"invalid key sk-ant-api03-AbCdEf123456789012345 provided"}"#
        let redacted = SecretRedactor.redact(body)
        XCTAssertFalse(redacted.contains("sk-ant-api03"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func testRedactsBearerTokens() {
        let body = "Authorization: Bearer abcdefghijklmnop.qrstuvwxyz-123456"
        let redacted = SecretRedactor.redact(body)
        XCTAssertFalse(redacted.contains("abcdefghijklmnop"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func testLeavesOrdinaryTextAlone() {
        let body = #"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited."}}"#
        XCTAssertEqual(SecretRedactor.redact(body), body)
    }
}
