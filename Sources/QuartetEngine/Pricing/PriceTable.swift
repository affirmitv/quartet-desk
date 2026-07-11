import Foundation

/// USD per million tokens for one model. Editable in Settings.
public struct ModelPrice: Codable, Sendable, Equatable, Hashable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
    }
}

/// Small bundled price table, keyed by model id. Models without an entry get
/// NO cost estimate (the UI says "price not set" and offers Settings) — we do
/// not invent numbers for models whose pricing we don't actually know.
public struct PriceTable: Codable, Sendable, Equatable {
    public var prices: [String: ModelPrice]

    public init(prices: [String: ModelPrice]) {
        self.prices = prices
    }

    /// Bundled defaults (verified prices only):
    /// - claude-opus-4-8: $5 in / $25 out per MTok (Anthropic published pricing)
    /// - gpt-5.6 tiers: sol-pro $5/$30, terra $2.5/$15, luna $1/$6 per MTok
    /// gemini-3.1-pro-preview and qwen3.7-max ship WITHOUT a bundled price —
    /// set them in Settings; until then their cost shows as "price not set".
    public static var bundledDefault: PriceTable {
        PriceTable(prices: [
            "claude-opus-4-8": ModelPrice(inputPerMTok: 5.0, outputPerMTok: 25.0),
            "openai/gpt-5.6-sol-pro": ModelPrice(inputPerMTok: 5.0, outputPerMTok: 30.0),
            "openai/gpt-5.6-terra": ModelPrice(inputPerMTok: 2.5, outputPerMTok: 15.0),
            "openai/gpt-5.6-luna": ModelPrice(inputPerMTok: 1.0, outputPerMTok: 6.0),
        ])
    }

    /// Lookup with vendor-prefix tolerance: exact match first, then match on the
    /// path component after the last "/" (so "gpt-5.6-terra" via OpenAI direct
    /// resolves against the bundled "openai/gpt-5.6-terra" entry and vice versa).
    ///
    /// Deterministic and honest on collision: if MULTIPLE vendor-prefixed
    /// entries share the bare name (e.g. "openai/gpt-4o" and "azure/gpt-4o" at
    /// different prices), returns nil — the model shows as unpriced instead of
    /// a number picked by unspecified Dictionary iteration order. The brand is
    /// "never invent a number".
    public func price(for modelID: String) -> ModelPrice? {
        if let exact = prices[modelID] { return exact }
        let bare = Self.bareName(modelID)
        if let byBare = prices[bare] { return byBare }
        let bareMatches = prices.filter { Self.bareName($0.key) == bare }
        return bareMatches.count == 1 ? bareMatches.first?.value : nil
    }

    static func bareName(_ modelID: String) -> String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }
}

/// One billable API call: which model, and what the provider reported.
public struct UsageLeg: Sendable, Equatable {
    public var modelID: String
    public var usage: TokenUsage

    public init(modelID: String, usage: TokenUsage) {
        self.modelID = modelID
        self.usage = usage
    }
}

public struct CostBreakdown: Codable, Sendable, Equatable {
    /// Sum over legs whose model has a known price.
    public var knownUSD: Double
    /// Models that contributed usage but have no configured price.
    public var unknownModels: [String]

    public init(knownUSD: Double, unknownModels: [String]) {
        self.knownUSD = knownUSD
        self.unknownModels = unknownModels
    }

    public var isFullyPriced: Bool { unknownModels.isEmpty }
}

public enum CostCalculator {
    public static func cost(legs: [UsageLeg], table: PriceTable) -> CostBreakdown {
        var known = 0.0
        var unknown: [String] = []
        for leg in legs {
            if let price = table.price(for: leg.modelID) {
                known += Double(leg.usage.inputTokens) / 1_000_000 * price.inputPerMTok
                known += Double(leg.usage.outputTokens) / 1_000_000 * price.outputPerMTok
            } else if !unknown.contains(leg.modelID) {
                unknown.append(leg.modelID)
            }
        }
        return CostBreakdown(knownUSD: known, unknownModels: unknown)
    }
}
