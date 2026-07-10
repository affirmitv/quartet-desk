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

    public init(id: UUID, seatName: String, provider: ProviderKind, modelID: String,
                isAnchor: Bool, text: String, usage: TokenUsage?,
                errorMessage: String?, revisionFailed: Bool) {
        self.id = id
        self.seatName = seatName
        self.provider = provider
        self.modelID = modelID
        self.isAnchor = isAnchor
        self.text = text
        self.usage = usage
        self.errorMessage = errorMessage
        self.revisionFailed = revisionFailed
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
    public var dissent: DissentOutcome
    public var cost: CostBreakdown

    public init(id: UUID, createdAt: Date, queryText: String, imageCount: Int,
                deliberate: Bool, seats: [SeatTranscript], synthesizedAnswer: String?,
                synthesisRaw: String?, synthesisUsage: TokenUsage?, synthesisError: String?,
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
        self.dissent = dissent
        self.cost = cost
    }
}
