import SwiftUI

/// Modest markdown renderer: fenced code blocks get a monospaced box; everything
/// else renders per-paragraph via AttributedString's inline markdown support.
/// Good enough for v1 — swap for a real markdown view when polishing.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                case .paragraph(let text):
                    Text(Self.inline(text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    enum Block: Equatable {
        case paragraph(String)
        case code(String)
    }

    static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var current: [String] = []
        var inCode = false
        var codeLines: [String] = []

        func flushParagraph() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            current = []
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                current.append(line)
            }
        }
        if inCode {
            // Unclosed fence (mid-stream) — render what we have as code.
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(markdown: text,
                                                  options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(text)
    }
}
