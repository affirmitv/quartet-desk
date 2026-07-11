import XCTest
import os
import QuartetEngine
@testable import QuartetProviders

/// Serves canned HTTP responses to URLSession in FIFO order and counts requests.
final class CannedResponder: @unchecked Sendable {
    static let shared = CannedResponder()
    private let lock = NSLock()
    private var queue: [(status: Int, headers: [String: String], body: Data)] = []
    private var requests = 0

    func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        requests = 0
    }

    func enqueue(status: Int, headers: [String: String] = [:], body: Data) {
        lock.lock(); defer { lock.unlock() }
        queue.append((status, headers, body))
    }

    func next() -> (status: Int, headers: [String: String], body: Data)? {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

final class CannedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let canned = CannedResponder.shared.next() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: canned.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: canned.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SSEStreamTransportTests: XCTestCase {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "transport-tests")

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        CannedResponder.shared.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CannedURLProtocol.self]
        session = URLSession(configuration: config)
    }

    private func makeTransport(maxAttempts: Int = 3) -> SSEStreamTransport {
        SSEStreamTransport(providerName: "TestProvider",
                           logger: Self.logger,
                           session: session,
                           retryPolicy: StreamRetryPolicy(maxAttempts: maxAttempts,
                                                          baseDelay: 0.01,
                                                          maxDelay: 0.05))
    }

    private static func makeRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://api.example.test/v1/messages")!)
    }

    /// Anthropic-shaped canned SSE frames for a complete tiny answer.
    private var completeSSEBody: Data {
        Data("""
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}

        event: message_delta
        data: {"type":"message_delta","usage":{"output_tokens":5},"delta":{"stop_reason":"end_turn"}}

        event: message_stop
        data: {"type":"message_stop"}


        """.utf8)
        // NB: the double blank line matters — SSE dispatches an event on an
        // EMPTY LINE, so the final event needs "\n\n" after its data line.
    }

    private func collect(_ transport: SSEStreamTransport) async throws -> [StreamChunk] {
        var chunks: [StreamChunk] = []
        let stream = transport.stream(makeRequest: { Self.makeRequest() },
                                      makeDecoder: { AnthropicSSEDecoder() })
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    func testCompleteStreamDecodesAllChunks() async throws {
        CannedResponder.shared.enqueue(status: 200, body: completeSSEBody)

        let chunks = try await collect(makeTransport())

        XCTAssertEqual(chunks, [
            .usage(TokenUsage(inputTokens: 10, outputTokens: 1)),
            .textDelta("hello"),
            .usage(TokenUsage(inputTokens: 10, outputTokens: 5)),
            .completed(stopReason: "end_turn"),
        ])
        XCTAssertEqual(CannedResponder.shared.requestCount, 1)
    }

    func test429ThenSuccessRetriesAndSucceeds() async throws {
        let envelope = #"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited."}}"#
        CannedResponder.shared.enqueue(status: 429,
                                       headers: ["Retry-After": "0"],
                                       body: Data(envelope.utf8))
        CannedResponder.shared.enqueue(status: 200, body: completeSSEBody)

        let chunks = try await collect(makeTransport())

        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(CannedResponder.shared.requestCount, 2, "429 must be retried exactly once here")
    }

    func testTruncationBeforeAnyChunkRetries() async throws {
        // EOF before any SSE event: truncated with zero yielded chunks → retryable.
        CannedResponder.shared.enqueue(status: 200, body: Data())
        CannedResponder.shared.enqueue(status: 200, body: completeSSEBody)

        let chunks = try await collect(makeTransport())

        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(CannedResponder.shared.requestCount, 2)
    }

    func testNoRetryAfterFirstYieldedChunk() async throws {
        // Data flowed, then the stream died before message_stop: retrying would
        // duplicate the partial answer downstream, so it must fail closed.
        let partial = Data("""
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"half an ans"}}

        """.utf8)
        CannedResponder.shared.enqueue(status: 200, body: partial)
        CannedResponder.shared.enqueue(status: 200, body: completeSSEBody) // must NOT be consumed

        do {
            _ = try await collect(makeTransport())
            XCTFail("expected truncatedStream")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .truncatedStream(provider: "TestProvider"))
        }
        XCTAssertEqual(CannedResponder.shared.requestCount, 1)
    }

    func testNonRetryableStatusFailsImmediatelyWithParsedMessage() async throws {
        let envelope = #"{"type":"error","error":{"type":"invalid_request_error","message":"model not found"}}"#
        CannedResponder.shared.enqueue(status: 404, body: Data(envelope.utf8))
        CannedResponder.shared.enqueue(status: 200, body: completeSSEBody) // must NOT be consumed

        do {
            _ = try await collect(makeTransport())
            XCTFail("expected http error")
        } catch let error as ProviderError {
            guard case .http(let status, let body) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(body, "invalid_request_error: model not found",
                           "HTTP errors must render the parsed envelope message, not raw JSON")
        }
        XCTAssertEqual(CannedResponder.shared.requestCount, 1)
    }

    func testRetriesExhaustSurfaceTheLastError() async throws {
        let envelope = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        for _ in 0..<3 {
            CannedResponder.shared.enqueue(status: 529, body: Data(envelope.utf8))
        }

        do {
            _ = try await collect(makeTransport(maxAttempts: 3))
            XCTFail("expected http error after exhausting retries")
        } catch let error as ProviderError {
            guard case .http(let status, let body) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 529)
            XCTAssertTrue(body.contains("Overloaded"))
        }
        XCTAssertEqual(CannedResponder.shared.requestCount, 3, "3 attempts total (1 + 2 retries)")
    }

    func testErrorBodySecretsAreRedacted() async throws {
        let envelope = #"{"error":{"message":"invalid key sk-ant-api03-AbCdEf12345678901234 supplied"}}"#
        CannedResponder.shared.enqueue(status: 401, body: Data(envelope.utf8))

        do {
            _ = try await collect(makeTransport())
            XCTFail("expected http error")
        } catch let error as ProviderError {
            guard case .http(_, let body) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertFalse(body.contains("sk-ant-api03"), "key material must never surface: \(body)")
            XCTAssertTrue(body.contains("[REDACTED]"))
        }
    }

    func testRetryAfterHTTPDateParses() {
        XCTAssertEqual(StreamingHTTP.parseRetryAfter("7"), 7)
        XCTAssertEqual(StreamingHTTP.parseRetryAfter(" 12 "), 12)
        // HTTP-date in the past clamps to 0.
        XCTAssertEqual(StreamingHTTP.parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT"), 0)
        XCTAssertNil(StreamingHTTP.parseRetryAfter("soon"))
    }

    func testAnthropicRequestBodySendsAdaptiveThinking() throws {
        let seat = Seat(name: "Anchor", provider: .anthropic, modelID: "claude-opus-4-8", isAnchor: true)
        let request = SeatRequest(seat: seat,
                                  messages: [ChatMessage(role: .user, text: "hi")],
                                  maxTokens: 100)
        let urlRequest = try AnthropicClient.makeURLRequest(request: request, apiKey: "k")
        let body = try XCTUnwrap(urlRequest.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try XCTUnwrap(object["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
    }
}
