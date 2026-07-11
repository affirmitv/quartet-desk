import SwiftUI
import QuartetEngine

/// Sidebar list of persisted runs.
///
/// Deliberately KEEPS the system sidebar material (`.listStyle(.sidebar)`
/// inside NavigationSplitView) — one of exactly two sanctioned translucency
/// surfaces (§1.4). Do NOT paint this with QDTheme.ink: behind-window blur is
/// the brand look here. (Smoke PNGs render it flat — offscreen caches can't
/// sample the backdrop; capture-only artifact, verify translucency live.)
struct HistorySidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedRecordID) {
            Section {
                if model.history.isEmpty {
                    Text("No runs yet")
                        .foregroundStyle(QDTheme.text45)
                } else {
                    ForEach(model.history) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(titleLine(record))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .qdMeta()
                        }
                        .tag(record.id)
                        .contextMenu {
                            Button("Delete Run", role: .destructive) {
                                model.deleteRecord(record.id)
                            }
                        }
                    }
                }
            } header: {
                Text("Runs").qdKicker()
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.selectedRecordID = nil
            } label: {
                Label("New Run", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QDGhostButtonStyle())
            .padding(8)
            .accessibilityLabel("New Run")
        }
    }

    private func titleLine(_ record: RunRecord) -> String {
        let flattened = record.queryText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.isEmpty ? "(empty query)" : String(flattened.prefix(60))
    }
}

/// Read-only view of a persisted run (same three tabs, driven by the record).
struct RecordDetailView: View {
    let record: RunRecord
    let priceTable: PriceTable
    @State private var tab: ResultTab = .answer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.queryText.replacingOccurrences(of: "\n", with: " ").prefix(120))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if record.deliberate { Label("Deliberated", systemImage: "arrow.triangle.2.circlepath") }
                        if record.imageCount > 0 { Label("\(record.imageCount) image(s)", systemImage: "photo") }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(QDTheme.text45)
                }
                Spacer()
            }
            .padding()

            QDTabBar(selection: $tab)

            QDHairline()

            Group {
                switch tab {
                case .answer:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let answer = record.synthesizedAnswer, !answer.isEmpty {
                                if record.synthesisTruncated {
                                    Label("Synthesis hit the token limit — this answer is INCOMPLETE.",
                                          systemImage: "scissors")
                                        .foregroundStyle(QDTheme.warn)
                                }
                                MarkdownText(markdown: answer)
                            } else {
                                Label(record.synthesisError ?? "No synthesized answer was produced.",
                                      systemImage: "xmark.octagon.fill")
                                    .foregroundStyle(QDTheme.bad)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                case .panel:
                    PanelPane(seatStates: record.seats.map { transcript in
                        var state = SeatLiveState(seat: Seat(id: transcript.id,
                                                             name: transcript.seatName,
                                                             provider: transcript.provider,
                                                             modelID: transcript.modelID,
                                                             isAnchor: transcript.isAnchor))
                        state.text = transcript.text
                        state.usage = transcript.usage
                        state.truncated = transcript.truncated
                        state.status = transcript.errorMessage.map { .failed($0) } ?? .done
                        if transcript.revisionFailed {
                            state.revisionFailedMessage = "Deliberation revision failed."
                        }
                        return state
                    }, priceTable: priceTable)
                case .dissent:
                    DissentPane(outcome: record.dissent, isRunning: false)
                }
            }
            // Material bottom bar; record content scrolls behind it (§1.4).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CostFooter(cost: record.cost)
            }
        }
        .background(QDTheme.ink)
    }
}
