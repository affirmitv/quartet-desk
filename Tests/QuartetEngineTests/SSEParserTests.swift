import XCTest
@testable import QuartetEngine

final class SSELineSplitterTests: XCTestCase {
    func testSplitsLFAndCRLF() {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in Array("data: a\r\ndata: b\n\n".utf8) {
            if let line = splitter.feed(byte) { lines.append(line) }
        }
        XCTAssertEqual(lines, ["data: a", "data: b", ""])
        XCTAssertNil(splitter.flushRemainder())
    }

    func testFlushRemainderReturnsUnterminatedTail() {
        var splitter = SSELineSplitter()
        for byte in Array("data: partial".utf8) {
            XCTAssertNil(splitter.feed(byte))
        }
        XCTAssertEqual(splitter.flushRemainder(), "data: partial")
    }

    func testMultiByteUTF8AcrossFeeds() {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in Array("data: héllo → 世界\n".utf8) {
            if let line = splitter.feed(byte) { lines.append(line) }
        }
        XCTAssertEqual(lines, ["data: héllo → 世界"])
    }
}

final class SSEParserTests: XCTestCase {
    private func run(_ lines: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for line in lines {
            if let event = parser.feed(line: line) { events.append(event) }
        }
        return events
    }

    func testSimpleDataEvent() {
        let events = run(["data: hello", ""])
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "hello")])
    }

    func testNamedEvent() {
        let events = run(["event: message_start", "data: {\"a\":1}", ""])
        XCTAssertEqual(events, [SSEEvent(event: "message_start", data: "{\"a\":1}")])
    }

    func testMultiLineDataJoinedWithNewline() {
        let events = run(["data: line1", "data: line2", ""])
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "line1\nline2")])
    }

    func testCommentsIgnored() {
        let events = run([": OPENROUTER PROCESSING", "data: x", ""])
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "x")])
    }

    func testBlankLineWithoutDataDispatchesNothing() {
        XCTAssertTrue(run(["", "", ""]).isEmpty)
    }

    func testEventNameResetBetweenEvents() {
        let events = run(["event: first", "data: 1", "", "data: 2", ""])
        XCTAssertEqual(events, [
            SSEEvent(event: "first", data: "1"),
            SSEEvent(event: nil, data: "2"),
        ])
    }

    func testNoLeadingSpaceRequiredAfterColon() {
        let events = run(["data:tight", ""])
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "tight")])
    }

    func testIdAndRetryIgnored() {
        let events = run(["id: 42", "retry: 100", "data: y", ""])
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "y")])
    }

    func testPendingFieldsFlagForTruncationDetection() {
        var parser = SSEParser()
        _ = parser.feed(line: "data: never dispatched")
        XCTAssertTrue(parser.hasPendingFields)
    }
}
