import SwiftUI
import QuartetEngine
import QuartetExport

enum ResultTab: String, CaseIterable, Identifiable {
    case answer = "ANSWER"
    case panel = "PANEL"
    case dissent = "DISSENT"
    var id: String { rawValue }
}

// MARK: - Tab bar

/// Brand tab bar (replaces the segmented picker): heavy tracked uppercase
/// labels with a 2pt ice underline on the selected tab. Binds to the SAME
/// selection the smoke harness drives (`model.resultTab` is untouched).
struct QDTabBar: View {
    @Binding var selection: ResultTab

    var body: some View {
        HStack(spacing: 24) {
            ForEach(ResultTab.allCases) { tab in
                TabItem(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
            }
            Spacer()
        }
        .frame(height: 40)
        .padding(.horizontal)
    }

    private struct TabItem: View {
        let tab: ResultTab
        let isSelected: Bool
        let select: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: select) {
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: .heavy))
                    .kerning(2.0)
                    .foregroundStyle(isSelected ? QDTheme.ice : (hovering ? Color.white : QDTheme.text45))
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Rectangle()
                                .fill(QDTheme.ice)
                                .frame(height: 2)
                                .offset(y: 8)
                        }
                    }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityIdentifier("result-tab-\(tab.rawValue)")
            // Label stays the visible rawValue ("PANEL") — the live UITest
            // queries buttons["PANEL"] etc.
            .accessibilityLabel(Text(tab.rawValue))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }
}

/// 1px brand hairline (flat replacement for Divider between brand panels).
struct QDHairline: View {
    var body: some View {
        Rectangle().fill(QDTheme.line).frame(height: 1)
    }
}

/// The three result tabs for the LIVE run. Tab selection lives on AppModel so
/// it survives view identity changes (and is drivable by the smoke harness).
struct LiveResultView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            QDTabBar(selection: $model.resultTab)

            QDHairline()

            Group {
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
            }
            // Material bottom bar: streamed content scrolls BEHIND it (§1.4).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let cost = model.lastRecord?.cost {
                    CostFooter(cost: cost)
                }
            }
        }
        .background(QDTheme.ink)
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
                        ProgressView().controlSize(.small).tint(QDTheme.ice)
                        Text("Panel round in progress — synthesis starts when the seats finish.")
                            .foregroundStyle(QDTheme.text60)
                    }
                case .streaming:
                    MarkdownText(markdown: displayText)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(QDTheme.ice)
                        Text("Synthesizing…").foregroundStyle(QDTheme.text60)
                    }
                case .done:
                    if record?.synthesisTruncated == true {
                        Label("Synthesis hit the token limit — this answer is INCOMPLETE.",
                              systemImage: "scissors")
                            .foregroundStyle(QDTheme.warn)
                    }
                    MarkdownText(markdown: displayText)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(QDTheme.bad)
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
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(state.seat.name)
                            .qdSectionHeader()
                        if state.seat.isAnchor {
                            // Mirrors landing `.badge`: ice background, ink text.
                            Text("ANCHOR")
                                .font(.system(size: 9, weight: .heavy))
                                .kerning(1.2)
                                .textCase(.uppercase)
                                .foregroundStyle(QDTheme.ink)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(QDTheme.ice)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .help("Anchor seat (synthesizer)")
                                .accessibilityLabel("Anchor seat")
                        }
                    }
                    Text(state.seat.modelID)
                        .qdMeta()
                        .lineLimit(1)
                }
                Spacer()
                statusBadge
            }

            if let revisionFailed = state.revisionFailedMessage {
                Label("Revision failed — showing round-1 answer. \(revisionFailed)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(QDTheme.warn)
            }

            if state.truncated {
                Label("Answer hit the model's token limit — it is INCOMPLETE.",
                      systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(QDTheme.warn)
                    .help("The provider stopped at max_tokens. Raise the per-seat token cap or shorten the query.")
            }

            QDHairline()

            ScrollView {
                if case .failed(let message) = state.status {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(QDTheme.bad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if state.status == .cancelled && state.text.isEmpty {
                    Text("Stopped before this seat answered.")
                        .foregroundStyle(QDTheme.text60)
                } else if state.text.isEmpty {
                    Text("Waiting…")
                        .foregroundStyle(QDTheme.text60)
                } else {
                    MarkdownText(markdown: state.text)
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)

            QDHairline()
            footer
        }
        .padding(10)
        .background(QDTheme.panel)
        // 2px ice top edge on the ANCHOR card only (echoes landing `.bcast`).
        .overlay(alignment: .top) {
            if state.seat.isAnchor {
                Rectangle().fill(QDTheme.ice).frame(height: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(QDTheme.line, lineWidth: 1))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state.status {
        case .idle:
            Image(systemName: "circle.dashed").foregroundStyle(QDTheme.text45)
        case .streaming, .revising:
            ProgressView().controlSize(.small).tint(QDTheme.ice)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(QDTheme.ice)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(QDTheme.bad)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(QDTheme.text45)
                .help("Run was stopped before this seat finished")
        }
    }

    private var footer: some View {
        HStack {
            if let usage = state.usage {
                Text("\(usage.inputTokens) in / \(usage.outputTokens) out")
                    .qdMeta()
                Spacer()
                if let price = priceTable.price(for: state.seat.modelID) {
                    let usd = Double(usage.inputTokens) / 1_000_000 * price.inputPerMTok
                        + Double(usage.outputTokens) / 1_000_000 * price.outputPerMTok
                    Text(String(format: "$%.4f", usd))
                        .qdMeta()
                } else {
                    Text("price not set")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(QDTheme.warn)
                        .help("No price configured for \(state.seat.modelID) — add one in Settings → Prices.")
                }
            } else {
                Text("no usage reported yet")
                    .qdMeta()
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
                            ProgressView().controlSize(.small).tint(QDTheme.ice)
                            Text("Dissent analysis arrives with synthesis.").foregroundStyle(QDTheme.text60)
                        }
                    } else {
                        ContentUnavailableView("No dissent analysis yet",
                                               systemImage: "person.2.slash",
                                               description: Text("Material disagreements between panelists appear here after a run."))
                    }
                case .notRun:
                    Label("Synthesis did not run — no dissent analysis available.",
                          systemImage: "minus.circle")
                        .foregroundStyle(QDTheme.text60)
                case .extractionFailed(let reason):
                    // FAIL CLOSED: never show "no dissent" when we simply couldn't parse it.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Dissent extraction failed — do NOT assume the panel agreed.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(QDTheme.text60)
                        Text("Read the PANEL tab to compare the answers yourself.")
                            .font(.callout)
                            .foregroundStyle(QDTheme.text60)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(QDTheme.bad.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(QDTheme.bad.opacity(0.5), lineWidth: 1))
                case .parsed(let items) where items.isEmpty:
                    Label("The panel materially agreed — no dissent recorded.",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(QDTheme.ice)
                case .parsed(let items):
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.topic).qdSectionHeader()
                            Label(item.who, systemImage: "person.fill")
                                .font(.caption)
                                .foregroundStyle(QDTheme.iceDim)
                            Text(item.position)
                                .font(.system(size: 13))
                                .foregroundStyle(QDTheme.text60)
                        }
                        .padding(10)
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(QDTheme.panel)
                        // 2px ice accent bar on the leading edge (clipped with the card).
                        .overlay(alignment: .leading) {
                            Rectangle().fill(QDTheme.ice).frame(width: 2)
                        }
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
                .foregroundStyle(QDTheme.ice)
            Text(MarkdownExporter.costLine(cost))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(cost.isFullyPriced ? QDTheme.text60 : QDTheme.warn)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // One of exactly two sanctioned translucency surfaces (§1.4): content
        // scrolls behind this bar via safeAreaInset.
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { QDHairline() }
        // NOTE: no .accessibilityElement(children: .combine) here — the live
        // UITest asserts on a staticText containing "$"; combining would hide it.
    }
}
