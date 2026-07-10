import XCTest
@testable import QuartetEngine

final class DissentParserTests: XCTestCase {
    func testValidFencedDissentBlock() {
        let output = """
        The best plan is X because of A and B.

        ===DISSENT===
        ```json
        {"dissents": [{"topic": "Budget split", "who": "Seat 3 (google/gemini-3.1-pro-preview)", "position": "Allocate 60% to paid ads instead of 30%."}]}
        ```
        """
        let (answer, outcome) = DissentParser.parse(synthesisOutput: output)
        XCTAssertEqual(answer, "The best plan is X because of A and B.")
        XCTAssertEqual(outcome, .parsed([
            DissentItem(topic: "Budget split",
                        who: "Seat 3 (google/gemini-3.1-pro-preview)",
                        position: "Allocate 60% to paid ads instead of 30%."),
        ]))
    }

    func testEmptyDissentsIsConsensus() {
        let output = "Answer.\n===DISSENT===\n```json\n{\"dissents\": []}\n```"
        let (_, outcome) = DissentParser.parse(synthesisOutput: output)
        XCTAssertEqual(outcome, .parsed([]))
    }

    func testBareJSONWithoutFenceAccepted() {
        let output = "Answer.\n===DISSENT===\n{\"dissents\": [{\"topic\": \"t\", \"who\": \"w\", \"position\": \"p\"}]}"
        let (_, outcome) = DissentParser.parse(synthesisOutput: output)
        XCTAssertEqual(outcome, .parsed([DissentItem(topic: "t", who: "w", position: "p")]))
    }

    func testMissingMarkerFailsClosed() {
        let (answer, outcome) = DissentParser.parse(synthesisOutput: "Just an answer, no marker.")
        XCTAssertEqual(answer, "Just an answer, no marker.")
        guard case .extractionFailed = outcome else {
            return XCTFail("expected extractionFailed, got \(outcome)")
        }
    }

    func testMarkerWithoutJSONFailsClosed() {
        let (_, outcome) = DissentParser.parse(synthesisOutput: "Answer.\n===DISSENT===\nno json here")
        guard case .extractionFailed = outcome else {
            return XCTFail("expected extractionFailed, got \(outcome)")
        }
    }

    func testMalformedJSONFailsClosed() {
        let output = "Answer.\n===DISSENT===\n```json\n{\"dissents\": [{\"oops\"]}\n```"
        let (_, outcome) = DissentParser.parse(synthesisOutput: output)
        guard case .extractionFailed = outcome else {
            return XCTFail("expected extractionFailed, got \(outcome)")
        }
    }

    func testWrongSchemaFailsClosed() {
        // Valid JSON, wrong shape (missing required keys) — must NOT be shown as consensus.
        let output = "Answer.\n===DISSENT===\n```json\n{\"disagreements\": []}\n```"
        let (_, outcome) = DissentParser.parse(synthesisOutput: output)
        guard case .extractionFailed = outcome else {
            return XCTFail("expected extractionFailed, got \(outcome)")
        }
    }

    func testUnclosedFenceFailsClosed() {
        let output = "Answer.\n===DISSENT===\n```json\n{\"dissents\": []}"
        let (_, outcome) = DissentParser.parse(synthesisOutput: output)
        guard case .extractionFailed = outcome else {
            return XCTFail("expected extractionFailed (truncated fence), got \(outcome)")
        }
    }

    func testBracesInsideStringsHandledByBareExtractor() {
        let json = "{\"dissents\": [{\"topic\": \"braces {inside} string\", \"who\": \"w\", \"position\": \"p\"}]}"
        let extracted = DissentParser.extractJSONBlock(from: "\n" + json + "\ntrailing prose")
        XCTAssertEqual(extracted, json)
    }
}
