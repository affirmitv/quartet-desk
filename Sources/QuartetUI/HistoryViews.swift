import SwiftUI
import QuartetEngine

/// Sidebar list of persisted runs.
struct HistorySidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedRecordID) {
            Section("Runs") {
                if model.history.isEmpty {
                    Text("No runs yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.history) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(titleLine(record))
                                .lineLimit(1)
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(record.id)
                        .contextMenu {
                            Button("Delete Run", role: .destructive) {
                                model.deleteRecord(record.id)
                            }
                        }
                    }
                }
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
            .padding(8)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.queryText.replacingOccurrences(of: "\n", with: " ").prefix(120))
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if record.deliberate { Label("Deliberated", systemImage: "arrow.triangle.2.circlepath") }
                        if record.imageCount > 0 { Label("\(record.imageCount) image(s)", systemImage: "photo") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Picker("", selection: $tab) {
                ForEach(ResultTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 6)

            Divider()

            switch tab {
            case .answer:
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let answer = record.synthesizedAnswer, !answer.isEmpty {
                            MarkdownText(markdown: answer)
                        } else {
                            Label(record.synthesisError ?? "No synthesized answer was produced.",
                                  systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
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
                    state.status = transcript.errorMessage.map { .failed($0) } ?? .done
                    if transcript.revisionFailed {
                        state.revisionFailedMessage = "Deliberation revision failed."
                    }
                    return state
                }, priceTable: priceTable)
            case .dissent:
                DissentPane(outcome: record.dissent, isRunning: false)
            }

            Divider()
            CostFooter(cost: record.cost)
        }
    }
}
