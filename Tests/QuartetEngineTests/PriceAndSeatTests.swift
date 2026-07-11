import XCTest
@testable import QuartetEngine

final class PriceTableTests: XCTestCase {
    func testBundledPricesMatchSpec() {
        let table = PriceTable.bundledDefault
        XCTAssertEqual(table.price(for: "claude-opus-4-8"), ModelPrice(inputPerMTok: 5.0, outputPerMTok: 25.0))
        XCTAssertEqual(table.price(for: "openai/gpt-5.6-sol-pro"), ModelPrice(inputPerMTok: 5.0, outputPerMTok: 30.0))
        XCTAssertEqual(table.price(for: "openai/gpt-5.6-terra"), ModelPrice(inputPerMTok: 2.5, outputPerMTok: 15.0))
        XCTAssertEqual(table.price(for: "openai/gpt-5.6-luna"), ModelPrice(inputPerMTok: 1.0, outputPerMTok: 6.0))
    }

    func testVendorPrefixToleranceBothDirections() {
        let table = PriceTable.bundledDefault
        // OpenAI-direct id resolves against the OpenRouter-prefixed bundled key.
        XCTAssertEqual(table.price(for: "gpt-5.6-terra"), ModelPrice(inputPerMTok: 2.5, outputPerMTok: 15.0))
        // Prefixed id resolves against a bare stored key.
        let custom = PriceTable(prices: ["qwen3.7-max": ModelPrice(inputPerMTok: 1.2, outputPerMTok: 4.8)])
        XCTAssertEqual(custom.price(for: "qwen/qwen3.7-max"), ModelPrice(inputPerMTok: 1.2, outputPerMTok: 4.8))
    }

    func testUnknownModelHasNoPrice() {
        XCTAssertNil(PriceTable.bundledDefault.price(for: "google/gemini-3.1-pro-preview"))
        XCTAssertNil(PriceTable.bundledDefault.price(for: "qwen/qwen3.7-max"))
    }

    func testAmbiguousBareNameCollisionReturnsNilNotARandomPick() {
        // Two vendor-prefixed entries share the bare name at different prices.
        // Dictionary iteration order is unspecified, so picking "the first" is
        // a coin flip per process — the honest answer is "unpriced".
        let table = PriceTable(prices: [
            "openai/gpt-4o": ModelPrice(inputPerMTok: 2.5, outputPerMTok: 10.0),
            "azure/gpt-4o": ModelPrice(inputPerMTok: 3.0, outputPerMTok: 12.0),
        ])
        XCTAssertNil(table.price(for: "gpt-4o"),
                     "Colliding bare names must be treated as unpriced, never resolved nondeterministically")
        // Exact matches still work, obviously.
        XCTAssertEqual(table.price(for: "openai/gpt-4o"), ModelPrice(inputPerMTok: 2.5, outputPerMTok: 10.0))
    }

    func testCostMath() {
        let legs = [
            UsageLeg(modelID: "claude-opus-4-8", usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 200_000)),
            UsageLeg(modelID: "openai/gpt-5.6-sol-pro", usage: TokenUsage(inputTokens: 500_000, outputTokens: 100_000)),
        ]
        let cost = CostCalculator.cost(legs: legs, table: .bundledDefault)
        // opus: 1.0*5 + 0.2*25 = 10.0 ; sol-pro: 0.5*5 + 0.1*30 = 5.5
        XCTAssertEqual(cost.knownUSD, 15.5, accuracy: 0.000001)
        XCTAssertTrue(cost.isFullyPriced)
    }

    func testUnknownModelsSurfacedNotZeroed() {
        let legs = [
            UsageLeg(modelID: "claude-opus-4-8", usage: TokenUsage(inputTokens: 100_000, outputTokens: 10_000)),
            UsageLeg(modelID: "google/gemini-3.1-pro-preview", usage: TokenUsage(inputTokens: 100_000, outputTokens: 10_000)),
        ]
        let cost = CostCalculator.cost(legs: legs, table: .bundledDefault)
        XCTAssertEqual(cost.unknownModels, ["google/gemini-3.1-pro-preview"])
        XCTAssertFalse(cost.isFullyPriced)
        XCTAssertEqual(cost.knownUSD, 0.1 * 5.0 + 0.01 * 25.0, accuracy: 0.000001)
    }
}

final class SeatConfigurationTests: XCTestCase {
    func testDefaultSeatsAreValidAndMatchSpec() throws {
        let seats = SeatConfiguration.defaultSeats()
        try SeatConfiguration.validate(seats)
        XCTAssertEqual(seats.count, 4)
        XCTAssertEqual(seats[0].provider, .anthropic)
        XCTAssertEqual(seats[0].modelID, "claude-opus-4-8")
        XCTAssertTrue(seats[0].isAnchor)
        XCTAssertEqual(seats[1].modelID, "openai/gpt-5.6-sol-pro")
        XCTAssertEqual(seats[2].modelID, "google/gemini-3.1-pro-preview")
        XCTAssertEqual(seats[3].modelID, "qwen/qwen3.7-max")
        XCTAssertTrue(seats[1...3].allSatisfy { $0.provider == .openrouter && !$0.isAnchor })
    }

    func testValidationRejectsWrongCount() {
        XCTAssertThrowsError(try SeatConfiguration.validate(Array(SeatConfiguration.defaultSeats().prefix(3)))) { error in
            XCTAssertEqual(error as? SeatConfigurationError, .wrongSeatCount(3))
        }
    }

    func testValidationRejectsZeroOrTwoAnchors() {
        var seats = SeatConfiguration.defaultSeats()
        seats[0].isAnchor = false
        XCTAssertThrowsError(try SeatConfiguration.validate(seats)) { error in
            XCTAssertEqual(error as? SeatConfigurationError, .anchorCount(0))
        }
        seats[0].isAnchor = true
        seats[1].isAnchor = true
        XCTAssertThrowsError(try SeatConfiguration.validate(seats)) { error in
            XCTAssertEqual(error as? SeatConfigurationError, .anchorCount(2))
        }
    }

    func testValidationRejectsEmptyModelID() {
        var seats = SeatConfiguration.defaultSeats()
        seats[2].modelID = "   "
        XCTAssertThrowsError(try SeatConfiguration.validate(seats)) { error in
            XCTAssertEqual(error as? SeatConfigurationError, .emptyModelID(seatName: seats[2].name))
        }
    }

    func testSeatCodableRoundTrip() throws {
        let seats = SeatConfiguration.defaultSeats()
        let data = try JSONEncoder().encode(seats)
        let decoded = try JSONDecoder().decode([Seat].self, from: data)
        XCTAssertEqual(decoded, seats)
    }
}

final class PromptAssemblyTests: XCTestCase {
    func testSynthesisPromptContainsEverySeatAnswerAndFailures() {
        let answers = [
            PanelAnswer(seatName: "Seat 1", modelID: "claude-opus-4-8", text: "Alpha answer"),
            PanelAnswer(seatName: "Seat 2", modelID: "openai/gpt-5.6-sol-pro", text: "Beta answer"),
        ]
        let failures = [
            PanelFailure(seatName: "Seat 3", modelID: "google/gemini-3.1-pro-preview", reason: "HTTP 429"),
        ]
        let prompt = PromptAssembly.synthesisUserPrompt(query: "Write me a marketing plan", answers: answers, failures: failures)
        XCTAssertTrue(prompt.contains("Write me a marketing plan"))
        XCTAssertTrue(prompt.contains("Alpha answer"))
        XCTAssertTrue(prompt.contains("Beta answer"))
        XCTAssertTrue(prompt.contains("Seat 3"))
        XCTAssertTrue(prompt.contains("HTTP 429"))
        XCTAssertTrue(prompt.contains(PromptAssembly.dissentMarker))
    }

    func testSynthesisSystemPromptSpecifiesMarkerAndSchema() {
        let system = PromptAssembly.synthesisSystemPrompt()
        XCTAssertTrue(system.contains(PromptAssembly.dissentMarker))
        XCTAssertTrue(system.contains(#""dissents""#))
        XCTAssertTrue(system.contains("topic"))
        XCTAssertTrue(system.contains("who"))
        XCTAssertTrue(system.contains("position"))
    }

    func testDeliberationPromptContainsOwnAndOtherAnswers() {
        let prompt = PromptAssembly.deliberationUserPrompt(
            query: "Q",
            ownAnswer: "MY-PREVIOUS",
            others: [PanelAnswer(seatName: "Seat 2", modelID: "m2", text: "OTHER-2")])
        XCTAssertTrue(prompt.contains("MY-PREVIOUS"))
        XCTAssertTrue(prompt.contains("OTHER-2"))
        XCTAssertTrue(prompt.contains("Q"))
    }
}
