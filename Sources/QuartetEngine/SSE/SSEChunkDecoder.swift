import Foundation

/// Provider-specific SSE-event → normalized-chunk decoding, behind one shape so
/// a single shared transport can own the stream loop, retry policy, validation,
/// and termination handling for every provider.
///
/// Fail-closed contract: `sawTerminal` must stay false until the provider's
/// explicit terminal marker is decoded. A transport that reaches EOF with
/// `sawTerminal == false` MUST treat the stream as truncated.
public protocol SSEChunkDecoder: Sendable {
    mutating func decode(_ event: SSEEvent) throws -> [StreamChunk]
    var sawTerminal: Bool { get }
}

extension AnthropicSSEDecoder: SSEChunkDecoder {}
extension OpenAIChatSSEDecoder: SSEChunkDecoder {}
