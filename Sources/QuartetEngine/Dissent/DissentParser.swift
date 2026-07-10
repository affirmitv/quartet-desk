import Foundation

/// One material disagreement between panelists.
public struct DissentItem: Codable, Sendable, Equatable, Hashable {
    public var topic: String
    public var who: String
    public var position: String

    public init(topic: String, who: String, position: String) {
        self.topic = topic
        self.who = who
        self.position = position
    }
}

/// Fail-closed dissent extraction result. `extractionFailed` means the UI must
/// show a "dissent extraction failed" banner — never pretend consensus.
public enum DissentOutcome: Codable, Sendable, Equatable {
    case parsed([DissentItem])
    case extractionFailed(reason: String)
    /// Synthesis itself never produced output (anchor failed / run aborted).
    case notRun
}

public enum DissentParser {
    private struct DissentEnvelope: Decodable {
        let dissents: [DissentItem]
    }

    /// Splits raw synthesis output into (answer, dissent outcome).
    ///
    /// Strict, fail-closed contract:
    /// - missing marker            → whole text is the answer, outcome = extractionFailed
    /// - marker but no JSON block  → extractionFailed
    /// - JSON that doesn't decode  → extractionFailed
    public static func parse(synthesisOutput: String) -> (answer: String, outcome: DissentOutcome) {
        guard let markerRange = synthesisOutput.range(of: PromptAssembly.dissentMarker) else {
            let answer = synthesisOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return (answer, .extractionFailed(reason: "Synthesizer output did not contain the \(PromptAssembly.dissentMarker) marker."))
        }

        let answer = String(synthesisOutput[..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(synthesisOutput[markerRange.upperBound...])

        guard let jsonText = extractJSONBlock(from: tail) else {
            return (answer, .extractionFailed(reason: "No JSON block found after the \(PromptAssembly.dissentMarker) marker."))
        }

        do {
            let envelope = try JSONDecoder().decode(DissentEnvelope.self, from: Data(jsonText.utf8))
            return (answer, .parsed(envelope.dissents))
        } catch {
            return (answer, .extractionFailed(reason: "Dissent JSON did not decode: \(error.localizedDescription)"))
        }
    }

    /// Extracts the contents of the first fenced code block after the marker,
    /// or — if there is no fence — the first balanced `{ ... }` object.
    static func extractJSONBlock(from text: String) -> String? {
        // Fenced form: ```json\n{...}\n``` (language tag optional)
        if let fenceStart = text.range(of: "```") {
            var afterFence = text[fenceStart.upperBound...]
            // Skip the optional language tag up to end of that line.
            if let newline = afterFence.firstIndex(of: "\n") {
                afterFence = afterFence[afterFence.index(after: newline)...]
            }
            if let fenceEnd = afterFence.range(of: "```") {
                let inner = String(afterFence[..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                return inner.isEmpty ? nil : inner
            }
            return nil // opened fence never closed — truncated output, fail closed
        }

        // Bare object form.
        guard let open = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                switch char {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[open...index])
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil // unbalanced — truncated output, fail closed
    }
}
