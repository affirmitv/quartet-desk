import XCTest
@testable import QuartetEngine

final class AnthropicSSEDecoderTests: XCTestCase {
    /// Canned frames modeled on the documented Messages API stream shape.
    func testFullMessageLifecycle() throws {
        var decoder = AnthropicSSEDecoder()
        var chunks: [StreamChunk] = []

        chunks += try decoder.decode(SSEEvent(event: "message_start", data:
            #"{"type":"message_start","message":{"id":"msg_1","type":"message","usage":{"input_tokens":25,"output_tokens":1}}}"#))
        chunks += try decoder.decode(SSEEvent(event: "content_block_start", data:
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
        chunks += try decoder.decode(SSEEvent(event: "content_block_delta", data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#))
        chunks += try decoder.decode(SSEEvent(event: "content_block_delta", data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#))
        chunks += try decoder.decode(SSEEvent(event: "content_block_stop", data:
            #"{"type":"content_block_stop","index":0}"#))
        chunks += try decoder.decode(SSEEvent(event: "message_delta", data:
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#))
        chunks += try decoder.decode(SSEEvent(event: "message_stop", data:
            #"{"type":"message_stop"}"#))

        XCTAssertEqual(chunks, [
            .usage(TokenUsage(inputTokens: 25, outputTokens: 1)),
            .textDelta("Hello"),
            .textDelta(" world"),
            .usage(TokenUsage(inputTokens: 25, outputTokens: 12)),
            .completed(stopReason: "end_turn"),
        ])
        XCTAssertTrue(decoder.sawTerminal)
    }

    func testTerminalNotSetWithoutMessageStop() throws {
        var decoder = AnthropicSSEDecoder()
        _ = try decoder.decode(SSEEvent(event: "content_block_delta", data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half an ans"}}"#))
        XCTAssertFalse(decoder.sawTerminal, "A stream without message_stop must be treated as truncated")
    }

    func testErrorEventThrows() {
        var decoder = AnthropicSSEDecoder()
        XCTAssertThrowsError(try decoder.decode(SSEEvent(event: "error", data:
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))) { error in
            XCTAssertEqual(error as? ProviderError, .api(message: "Overloaded"))
        }
    }

    func testPingIgnored() throws {
        var decoder = AnthropicSSEDecoder()
        XCTAssertEqual(try decoder.decode(SSEEvent(event: "ping", data: #"{"type":"ping"}"#)), [])
    }

    func testNonJSONDataThrowsMalformed() {
        var decoder = AnthropicSSEDecoder()
        XCTAssertThrowsError(try decoder.decode(SSEEvent(event: nil, data: "not json"))) { error in
            guard case ProviderError.malformedEvent = error as! ProviderError else {
                return XCTFail("expected malformedEvent, got \(error)")
            }
        }
    }

    func testThinkingDeltaIgnored() throws {
        var decoder = AnthropicSSEDecoder()
        let chunks = try decoder.decode(SSEEvent(event: "content_block_delta", data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#))
        XCTAssertEqual(chunks, [])
    }
}

final class OpenAIChatSSEDecoderTests: XCTestCase {
    func testFullChunkLifecycle() throws {
        var decoder = OpenAIChatSSEDecoder()
        var chunks: [StreamChunk] = []

        chunks += try decoder.decode(SSEEvent(data:
            #"{"id":"c1","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#))
        chunks += try decoder.decode(SSEEvent(data:
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#))
        chunks += try decoder.decode(SSEEvent(data:
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":" there"},"finish_reason":null}]}"#))
        chunks += try decoder.decode(SSEEvent(data:
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#))
        chunks += try decoder.decode(SSEEvent(data:
            #"{"id":"c1","choices":[],"usage":{"prompt_tokens":40,"completion_tokens":9,"total_tokens":49}}"#))
        chunks += try decoder.decode(SSEEvent(data: "[DONE]"))

        XCTAssertEqual(chunks, [
            .textDelta("Hi"),
            .textDelta(" there"),
            .usage(TokenUsage(inputTokens: 40, outputTokens: 9)),
            .completed(stopReason: "stop"),
        ])
        XCTAssertTrue(decoder.sawTerminal)
    }

    func testTerminalRequiresDone() throws {
        var decoder = OpenAIChatSSEDecoder()
        _ = try decoder.decode(SSEEvent(data:
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#))
        XCTAssertFalse(decoder.sawTerminal, "finish_reason alone is not terminal; [DONE] is")
    }

    func testMidStreamErrorObjectThrows() {
        var decoder = OpenAIChatSSEDecoder()
        XCTAssertThrowsError(try decoder.decode(SSEEvent(data:
            #"{"error":{"message":"Rate limit exceeded","code":429}}"#))) { error in
            XCTAssertEqual(error as? ProviderError, .api(message: "Rate limit exceeded"))
        }
    }

    func testMalformedChunkThrows() {
        var decoder = OpenAIChatSSEDecoder()
        XCTAssertThrowsError(try decoder.decode(SSEEvent(data: "{{{"))) { error in
            guard case ProviderError.malformedEvent = error as! ProviderError else {
                return XCTFail("expected malformedEvent, got \(error)")
            }
        }
    }
}
