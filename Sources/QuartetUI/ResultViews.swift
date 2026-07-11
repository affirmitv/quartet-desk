import SwiftUI
import QuartetEngine
import QuartetExport

enum ResultTab: String, CaseIterable, Identifiable {
    case answer = "ANSWER"
    case panel = "PANEL"
    case dissent = "DISSENT"
    var id: String { rawValue }
}

/// The three result tabs for the LIVE run. Tab selection lives on AppModel so
/// it survives view identity changes (and is drivable by the smoke harness).
struct LiveResultView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.resultTab) {
                ForEach(ResultTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            switch model.resultTab {
            case .answer:
                AnswerPane(status: model.synthesisStatus,
                           liveText: model.liveAnswerText,
                           record: model.lastRecord)
            case .panel:
                PanelPane(seatStates: model.seatStates, priceTable: model.priceTable)
            case .dissent:
                DissentPane(outcome: model.lastRecord?.dissent,
                            isRunning: model.isRunning)
            }

            if let cost = model.lastRecord?.cost {
                Divider()
                CostFooter(cost: cost)
            }
        }
    }
}

// MARK: - ANSWER

struct AnswerPane: View {
    let status: SynthesisLiveStatus
    let liveText: String
    let record: RunRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch status {
                case .idle:
                    ContentUnavailableView("No answer yet",
                                           systemImage: "person.3",
                                           description: Text("Run the quartet to get a synthesized answer with dissent surfaced."))
                case .waitingForPanel:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Panel round in progress — synthesis starts when the seats finish.")
                            .foregroundStyle(.secondary)
                    }
                case .streaming:
                    MarkdownText(markdown: displayText)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Synthesizing…").foregroundStyle(.secondary)
                    }
                case .done:
                    if record?.synthesisTruncated == true {
                        Label("Synthesis hit the token limit — this answer is INCOMPLETE.",
                              systemImage: "scissors")
                            .foregroundStyle(.orange)
                    }
                    MarkdownText(markdown: displayText)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    if !displayText.isEmpty {
                        MarkdownText(markdown: displayText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    /// While streaming, hide everything from the dissent marker onward so the
    /// raw JSON tail doesn't flash in the answer pane.
    private var displayText: String {
        if let marker = liveText.range(of: PromptAssembly.dissentMarker) {
            return String(liveText[..<marker.lowerBound])
        }
        return liveText
    }
}

// MARK: - PANEL

struct PanelPane: View {
    let seatStates: [SeatLiveState]
    let priceTable: PriceTable

    var body: some View {
        if seatStates.isEmpty {
            ContentUnavailableView("No panel yet",
                                   systemImage: "square.grid.2x2",
                                   description: Text("Each seat's full answer appears here during a run."))
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(seatStates) { state in
                        SeatCard(state: state, priceTable: priceTable)
                            .frame(width: 340)
                    }
                }
                .padding(8)
            }
        }
    }
}

struct SeatCard: View {
    let state: SeatLiveState
    let priceTable: PriceTable

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(state.seat.name).font(.headline)
                        if state.seat.isAnchor {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Anchor seat (synthesizer)")
                        }
                    }
                    Text(state.seat.modelID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                statusBadge
            }

            if let revisionFailed = state.revisionFailedMessage {
                Label("Revision failed — showing round-1 answer. \(revisionFailed)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if state.truncated {
                Label("Answer hit the model's token limit — it is INCOMPLETE.",
                      systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The provider stopped at max_tokens. Raise the per-seat token cap or shorten the query.")
            }

            Divider()

            ScrollView {
                if case .failed(let message) = state.status {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if state.status == .cancelled && state.text.isEmpty {
                    Text("Stopped before this seat answered.")
                        .foregroundStyle(.secondary)
                } else if state.text.isEmpty {
                    Text("Waiting…")
                        .foregroundStyle(.secondary)
                } else {
                    MarkdownText(markdown: state.text)
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)

            Divider()
            footer
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state.status {
        case .idle:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .streaming, .revising:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.secondary)
                .help("Run was stopped before this seat finished")
        }
    }

    private var footer: some View {
        HStack {
            if let usage = state.usage {
                Text("\(usage.inputTokens) in / \(usage.outputTokens) out")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let price = priceTable.price(for: state.seat.modelID) {
                    let usd = Double(usage.inputTokens) / 1_000_000 * price.inputPerMTok
                        + Double(usage.outputTokens) / 1_000_000 * price.outputPerMTok
                    Text(String(format: "$%.4f", usd))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("price not set")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("No price configured for \(state.seat.modelID) — add one in Settings → Prices.")
                }
            } else {
                Text("no usage reported yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

// MARK: - DISSENT

struct DissentPane: View {
    let outcome: DissentOutcome?
    let isRunning: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch outcome {
                case nil:
                    if isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Dissent analysis arrives with synthesis.").foregroundStyle(.secondary)
                        }
                    } else {
                        ContentUnavailableView("No dissent analysis yet",
                                               systemImage: "person.2.slash",
                                               description: Text("Material disagreements between panelists appear here after a run."))
                    }
                case .notRun:
                    Label("Synthesis did not run — no dissent analysis available.",
                          systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                case .extractionFailed(let reason):
                    // FAIL CLOSED: never show "no dissent" when we simply couldn't parse it.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Dissent extraction failed — do NOT assume the panel agreed.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Read the PANEL tab to compare the answers yourself.")
                            .font(.callout)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                case .parsed(let items) where items.isEmpty:
                    Label("The panel materially agreed — no dissent recorded.",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                case .parsed(let items):
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.topic).font(.headline)
                            Label(item.who, systemImage: "person.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.position)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

// MARK: - Cost footer

struct CostFooter: View {
    let cost: CostBreakdown

    var body: some View {
        HStack {
            Image(systemName: "dollarsign.circle")
            Text(MarkdownExporter.costLine(cost))
                .font(.callout)
                .foregroundStyle(cost.isFullyPriced ? Color.secondary : Color.orange)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
