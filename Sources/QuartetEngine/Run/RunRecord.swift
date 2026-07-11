import Foundation

/// Final transcript of one seat within a finished run.
public struct SeatTranscript: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var seatName: String
    public var provider: ProviderKind
    public var modelID: String
    public var isAnchor: Bool
    /// Final answer text (post-deliberation if a revision succeeded).
    public var text: String
    /// Total provider-reported usage across all this seat's calls in the run.
    public var usage: TokenUsage?
    /// Non-nil if the seat produced no usable answer.
    public var errorMessage: String?
    /// True when the Deliberate revision failed and the round-1 answer was kept.
    public var revisionFailed: Bool
    /// True when the final text hit the provider token limit (stop reason
    /// "max_tokens"/"length") — the answer is real but INCOMPLETE, and the UI
    /// must say so ("a half answer is never shown as complete").
    public var truncated: Bool

    public init(id: UUID, seatName: String, provider: ProviderKind, modelID: String,
                isAnchor: Bool, text: String, usage: TokenUsage?,
                errorMessage: String?, revisionFailed: Bool, truncated: Bool = false) {
        self.id = id
        self.seatName = seatName
        self.provider = provider
        self.modelID = modelID
        self.isAnchor = isAnchor
        self.text = text
        self.usage = usage
        self.errorMessage = errorMessage
        self.revisionFailed = revisionFailed
        self.truncated = truncated
    }

    /// Back-compat decoding: history files written before `truncated` existed
    /// decode with `truncated = false`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        seatName = try container.decode(String.self, forKey: .seatName)
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        modelID = try container.decode(String.self, forKey: .modelID)
        isAnchor = try container.decode(Bool.self, forKey: .isAnchor)
        text = try container.decode(String.self, forKey: .text)
        usage = try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        revisionFailed = try container.decode(Bool.self, forKey: .revisionFailed)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    public var succeeded: Bool { errorMessage == nil }
}

/// One persisted quartet run (JSON file under Application Support/QuartetDesk/runs/).
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var queryText: String
    /// Image payloads are not persisted in v1 (only the count) to keep history light.
    public var imageCount: Int
    public var deliberate: Bool
    public var seats: [SeatTranscript]
    public var synthesizedAnswer: String?
    /// Raw anchor synthesis output (answer + marker + JSON), kept for auditability.
    public var synthesisRaw: String?
    public var synthesisUsage: TokenUsage?
    public var synthesisError: String?
    /// True when the synthesis output hit the token limit — the answer (and
    /// possibly the dissent JSON) may be cut off; the UI must surface it.
    public var synthesisTruncated: Bool
    public var dissent: DissentOutcome
    public var cost: CostBreakdown

    public init(id: UUID, createdAt: Date, queryText: String, imageCount: Int,
                deliberate: Bool, seats: [SeatTranscript], synthesizedAnswer: String?,
                synthesisRaw: String?, synthesisUsage: TokenUsage?, synthesisError: String?,
                synthesisTruncated: Bool = false,
                dissent: DissentOutcome, cost: CostBreakdown) {
        self.id = id
        self.createdAt = createdAt
        self.queryText = queryText
        self.imageCount = imageCount
        self.deliberate = deliberate
        self.seats = seats
        self.synthesizedAnswer = synthesizedAnswer
        self.synthesisRaw = synthesisRaw
        self.synthesisUsage = synthesisUsage
        self.synthesisError = synthesisError
        self.synthesisTruncated = synthesisTruncated
        self.dissent = dissent
        self.cost = cost
    }

    /// Back-compat decoding: history files written before `synthesisTruncated`
    /// existed decode with `false`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        queryText = try container.decode(String.self, forKey: .queryText)
        imageCount = try container.decode(Int.self, forKey: .imageCount)
        deliberate = try container.decode(Bool.self, forKey: .deliberate)
        seats = try container.decode([SeatTranscript].self, forKey: .seats)
        synthesizedAnswer = try container.decodeIfPresent(String.self, forKey: .synthesizedAnswer)
        synthesisRaw = try container.decodeIfPresent(String.self, forKey: .synthesisRaw)
        synthesisUsage = try container.decodeIfPresent(TokenUsage.self, forKey: .synthesisUsage)
        synthesisError = try container.decodeIfPresent(String.self, forKey: .synthesisError)
        synthesisTruncated = try container.decodeIfPresent(Bool.self, forKey: .synthesisTruncated) ?? false
        dissent = try container.decode(DissentOutcome.self, forKey: .dissent)
        cost = try container.decode(CostBreakdown.self, forKey: .cost)
    }
}
