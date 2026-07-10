import Foundation

/// One dispatched Server-Sent Event.
public struct SSEEvent: Sendable, Equatable {
    /// Value of the `event:` field, if any (Anthropic sets it; OpenAI-compat does not).
    public var event: String?
    /// Joined `data:` lines (newline-separated when multi-line).
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental SSE field parser per the WHATWG EventSource spec subset that
/// all three providers use: `event:`, `data:` (possibly multi-line), `:` comments,
/// dispatch on blank line. `id:`/`retry:` are accepted and ignored.
public struct SSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feed one line (no terminator). Returns an event when a blank line
    /// dispatches accumulated fields, otherwise nil.
    public mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty {
            defer {
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
            }
            guard !dataLines.isEmpty else { return nil } // event name without data dispatches nothing
            return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        }

        if line.hasPrefix(":") { return nil } // comment (OpenRouter sends ": OPENROUTER PROCESSING")

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() } // single leading space is stripped per spec
        } else {
            field = line[...]
            value = ""
        }

        switch field {
        case "event":
            eventName = String(value)
        case "data":
            dataLines.append(String(value))
        default:
            break // id, retry, unknown fields: ignore
        }
        return nil
    }

    /// True if fields are buffered but not yet dispatched (truncation hint at EOF).
    public var hasPendingFields: Bool {
        eventName != nil || !dataLines.isEmpty
    }
}
