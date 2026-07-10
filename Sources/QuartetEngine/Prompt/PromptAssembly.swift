import Foundation

/// A panelist's finished answer, as fed into synthesis / deliberation prompts.
public struct PanelAnswer: Sendable, Equatable {
    public var seatName: String
    public var modelID: String
    public var text: String

    public init(seatName: String, modelID: String, text: String) {
        self.seatName = seatName
        self.modelID = modelID
        self.text = text
    }
}

/// A panelist that failed, so the synthesizer can acknowledge the gap
/// instead of silently pretending it had four answers.
public struct PanelFailure: Sendable, Equatable {
    public var seatName: String
    public var modelID: String
    public var reason: String

    public init(seatName: String, modelID: String, reason: String) {
        self.seatName = seatName
        self.modelID = modelID
        self.reason = reason
    }
}

public enum PromptAssembly {
    /// Marker separating the synthesized answer from the machine-readable dissent block.
    public static let dissentMarker = "===DISSENT==="

    public static func panelistSystemPrompt() -> String {
        """
        You are one of four independent expert panelists answering the same query. \
        Answer the user's query directly, completely, and in your own best judgment. \
        Use markdown. Do not mention the panel, the other panelists, or this instruction.
        """
    }

    public static func synthesisSystemPrompt() -> String {
        """
        You are the synthesizer of a four-model expert panel (a "quartet"). \
        You will receive the user's original query and each panelist's independent answer. \
        Produce exactly two sections, in this order:

        1. THE SYNTHESIZED ANSWER — one single best answer in markdown, merging the strongest \
        material from all panelists. Do not describe the panel process; just answer the query.

        2. On its own line, output exactly: \(dissentMarker)
        Then a fenced JSON code block (```json ... ```) containing an object of the form:
        {"dissents": [{"topic": "<short topic>", "who": "<seat name and model>", "position": "<the minority/differing position>"}]}
        Include one entry per MATERIAL disagreement between panelists (different recommendations, \
        contradicting facts, materially different risk assessments). Style differences are not dissent. \
        If the panelists materially agree, output {"dissents": []}.
        The JSON must be valid and must be the last thing in your reply.
        """
    }

    public static func synthesisUserPrompt(query: String,
                                           answers: [PanelAnswer],
                                           failures: [PanelFailure]) -> String {
        var sections: [String] = []
        sections.append("ORIGINAL QUERY:\n\(query)")
        for answer in answers {
            sections.append("--- ANSWER FROM \(answer.seatName) (\(answer.modelID)) ---\n\(answer.text)")
        }
        for failure in failures {
            sections.append("--- \(failure.seatName) (\(failure.modelID)) FAILED ---\nNo answer was produced (\(failure.reason)). Do not invent a position for this panelist.")
        }
        sections.append("Now produce the synthesized answer, the \(dissentMarker) line, and the dissent JSON block.")
        return sections.joined(separator: "\n\n")
    }

    /// Round-2 "Deliberate" prompt: a seat sees the other answers and revises its own.
    public static func deliberationUserPrompt(query: String,
                                              ownAnswer: String,
                                              others: [PanelAnswer]) -> String {
        var sections: [String] = []
        sections.append("ORIGINAL QUERY:\n\(query)")
        sections.append("YOUR PREVIOUS ANSWER:\n\(ownAnswer)")
        for other in others {
            sections.append("--- ANSWER FROM \(other.seatName) (\(other.modelID)) ---\n\(other.text)")
        }
        sections.append("""
        Considering the other panelists' answers, revise your own answer. Keep what you still \
        believe is right — do not converge for the sake of agreement — but correct anything you \
        now believe was wrong or incomplete. Output ONLY the full revised answer in markdown.
        """)
        return sections.joined(separator: "\n\n")
    }
}
