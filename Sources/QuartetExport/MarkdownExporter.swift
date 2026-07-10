import Foundation
import QuartetEngine

/// Builds .md export payloads from a finished run. Pure string assembly —
/// the UI layer owns NSSavePanel / file writing.
public enum MarkdownExporter {
    /// Just the synthesized answer (or an explicit failure note — never an empty file).
    public static func answerMarkdown(_ record: RunRecord) -> String {
        var lines: [String] = []
        lines.append("# Quartet Answer")
        lines.append("")
        lines.append("> Query: \(record.queryText.replacingOccurrences(of: "\n", with: " "))")
        lines.append("> Date: \(Self.dateFormatter.string(from: record.createdAt))")
        lines.append("")
        if let answer = record.synthesizedAnswer, !answer.isEmpty {
            lines.append(answer)
        } else {
            lines.append("**No synthesized answer was produced.** \(record.synthesisError ?? "")")
        }
        lines.append("")
        lines.append(contentsOf: dissentSection(record))
        return lines.joined(separator: "\n")
    }

    /// Full run: metadata, synthesized answer, dissent, every panelist's answer, cost.
    public static func fullRunMarkdown(_ record: RunRecord) -> String {
        var lines: [String] = []
        lines.append("# Quartet Run — \(Self.dateFormatter.string(from: record.createdAt))")
        lines.append("")
        lines.append("## Query")
        lines.append("")
        lines.append(record.queryText)
        if record.imageCount > 0 {
            lines.append("")
            lines.append("_\(record.imageCount) image attachment(s) were sent with this query (not embedded in this export)._")
        }
        lines.append("")
        lines.append("## Synthesized Answer")
        lines.append("")
        if let answer = record.synthesizedAnswer, !answer.isEmpty {
            lines.append(answer)
        } else {
            lines.append("**No synthesized answer was produced.** \(record.synthesisError ?? "")")
        }
        lines.append("")
        lines.append(contentsOf: dissentSection(record))
        lines.append("")
        lines.append("## Panel")
        for seat in record.seats {
            lines.append("")
            lines.append("### \(seat.seatName) — \(seat.modelID)\(seat.isAnchor ? " (anchor)" : "")")
            lines.append("")
            if let error = seat.errorMessage {
                lines.append("**FAILED:** \(error)")
            } else {
                if seat.revisionFailed {
                    lines.append("_Deliberation revision failed — this is the round-1 answer._")
                    lines.append("")
                }
                lines.append(seat.text)
            }
            if let usage = seat.usage {
                lines.append("")
                lines.append("_Usage: \(usage.inputTokens) in / \(usage.outputTokens) out tokens._")
            }
        }
        lines.append("")
        lines.append("## Cost")
        lines.append("")
        lines.append(costLine(record.cost))
        return lines.joined(separator: "\n")
    }

    public static func costLine(_ cost: CostBreakdown) -> String {
        if cost.isFullyPriced {
            return String(format: "Estimated cost: $%.4f (from provider-reported usage × configured prices).", cost.knownUSD)
        }
        let missing = cost.unknownModels.joined(separator: ", ")
        return String(format: "Estimated cost: $%.4f for priced models. No price configured for: %@.", cost.knownUSD, missing)
    }

    private static func dissentSection(_ record: RunRecord) -> [String] {
        var lines: [String] = ["## Dissent", ""]
        switch record.dissent {
        case .parsed(let items) where items.isEmpty:
            lines.append("The panel materially agreed — no dissent recorded.")
        case .parsed(let items):
            lines.append("| Topic | Who | Position |")
            lines.append("|---|---|---|")
            for item in items {
                lines.append("| \(escapeCell(item.topic)) | \(escapeCell(item.who)) | \(escapeCell(item.position)) |")
            }
        case .extractionFailed(let reason):
            lines.append("**Dissent extraction FAILED** — do not assume consensus. Reason: \(reason)")
        case .notRun:
            lines.append("Synthesis did not run — no dissent analysis available.")
        }
        return lines
    }

    private static func escapeCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
