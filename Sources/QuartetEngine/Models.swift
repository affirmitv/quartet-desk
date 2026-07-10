import Foundation

/// Which API a seat talks to.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic
    case openai
    case openrouter

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .openrouter: return "OpenRouter"
        }
    }
}

/// One panelist: a provider + model id. Exactly one seat is the anchor
/// (the synthesizer that merges the four answers and extracts dissent).
public struct Seat: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var provider: ProviderKind
    public var modelID: String
    public var isAnchor: Bool

    public init(id: UUID = UUID(), name: String, provider: ProviderKind, modelID: String, isAnchor: Bool = false) {
        self.id = id
        self.name = name
        self.provider = provider
        self.modelID = modelID
        self.isAnchor = isAnchor
    }
}

public enum SeatConfigurationError: Error, Equatable, LocalizedError {
    case wrongSeatCount(Int)
    case anchorCount(Int)
    case emptyModelID(seatName: String)

    public var errorDescription: String? {
        switch self {
        case .wrongSeatCount(let n): return "A quartet needs exactly 4 seats (got \(n))."
        case .anchorCount(let n): return "Exactly one seat must be the anchor/synthesizer (got \(n))."
        case .emptyModelID(let name): return "Seat \"\(name)\" has an empty model id."
        }
    }
}

public enum SeatConfiguration {
    /// Default quartet. Seat 1 (anchor) goes direct to Anthropic; seats 2-4 via OpenRouter.
    public static func defaultSeats() -> [Seat] {
        [
            Seat(name: "Seat 1 — Anchor", provider: .anthropic, modelID: "claude-opus-4-8", isAnchor: true),
            Seat(name: "Seat 2", provider: .openrouter, modelID: "openai/gpt-5.6-sol-pro"),
            Seat(name: "Seat 3", provider: .openrouter, modelID: "google/gemini-3.1-pro-preview"),
            Seat(name: "Seat 4", provider: .openrouter, modelID: "qwen/qwen3.7-max"),
        ]
    }

    public static func validate(_ seats: [Seat]) throws {
        guard seats.count == 4 else { throw SeatConfigurationError.wrongSeatCount(seats.count) }
        let anchors = seats.filter(\.isAnchor).count
        guard anchors == 1 else { throw SeatConfigurationError.anchorCount(anchors) }
        for seat in seats where seat.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SeatConfigurationError.emptyModelID(seatName: seat.name)
        }
    }
}

/// A user-supplied image, already downscaled/re-encoded by the UI layer.
/// The engine never touches AppKit/ImageIO — it only carries the payload.
public struct ImageAttachment: Codable, Sendable, Equatable, Hashable {
    /// Base64-encoded image bytes (no data-URL prefix).
    public var base64Data: String
    /// e.g. "image/jpeg" or "image/png"
    public var mediaType: String

    public init(base64Data: String, mediaType: String) {
        self.base64Data = base64Data
        self.mediaType = mediaType
    }
}

/// Provider-agnostic chat message. Providers translate this to their wire shape.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case system, user, assistant
    }

    public var role: Role
    public var text: String
    public var images: [ImageAttachment]

    public init(role: Role, text: String, images: [ImageAttachment] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

/// One streaming completion request for a seat.
public struct SeatRequest: Sendable {
    public var seat: Seat
    public var messages: [ChatMessage]
    public var maxTokens: Int

    public init(seat: Seat, messages: [ChatMessage], maxTokens: Int) {
        self.seat = seat
        self.messages = messages
        self.maxTokens = maxTokens
    }
}

/// Token accounting as reported by the provider (never estimated locally).
public struct TokenUsage: Codable, Sendable, Equatable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: lhs.inputTokens + rhs.inputTokens,
                   outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
}

public enum Limits {
    /// Soft cap on the composer. The UI warns past this but does not block.
    public static let querySoftCapCharacters = 32_000
    /// Longest image side after downscale (enforced by the UI image pipeline).
    public static let imageMaxPixelLongSide = 2048
    /// Max re-encoded JPEG byte size (enforced by the UI image pipeline).
    public static let imageMaxBytes = 4 * 1024 * 1024
}
