import Foundation

/// Byte-level line splitter for SSE transports.
///
/// We deliberately do NOT use `URLSession.AsyncBytes.lines` because it drops
/// blank lines — and SSE dispatches events on blank lines. Buffering raw bytes
/// until `\n` also keeps multi-byte UTF-8 sequences intact across chunk
/// boundaries.
public struct SSELineSplitter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feed one byte. Returns a completed line (without its terminator) when a
    /// `\n` is seen; handles `\r\n` by stripping the trailing `\r`.
    public mutating func feed(_ byte: UInt8) -> String? {
        if byte == 0x0A { // \n
            var bytes = buffer
            buffer.removeAll(keepingCapacity: true)
            if bytes.last == 0x0D { bytes.removeLast() } // \r
            return String(decoding: bytes, as: UTF8.self)
        }
        buffer.append(byte)
        return nil
    }

    /// Any unterminated trailing bytes when the transport ends.
    /// A non-nil remainder on a supposedly-finished stream is a truncation signal.
    public mutating func flushRemainder() -> String? {
        guard !buffer.isEmpty else { return nil }
        var bytes = buffer
        buffer.removeAll(keepingCapacity: true)
        if bytes.last == 0x0D { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
