import SwiftUI
import AppKit
import os
import QuartetEngine
import QuartetExport

/// Main window: history sidebar + (live run | selected record) detail.
public struct QuartetRootView: View {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "root-ui")

    @Bindable var model: AppModel
    @State private var exportError: String?
    @Environment(\.openSettings) private var openSettings

    init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            HistorySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                exportMenu
            }
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .navigationTitle("Quartet Desk")
        .onReceive(DistributedNotificationCenter.default().publisher(for: SmokeCapture.openSettingsNotification)) { _ in
            // Smoke harness only — inert unless launched with --smoke-shots.
            guard SmokeCapture.isEnabled else { return }
            openSettings()
        }
    }

    @ViewBuilder
    private var detail: some View {
        // The warnings banner renders in BOTH detail branches — a mid-session
        // failure (settings save, history delete) must be visible even while a
        // history record is selected, not only on the new-run screen.
        if let record = model.selectedRecord {
            VStack(spacing: 0) {
                warningsBannerIfNeeded
                RecordDetailView(record: record, priceTable: model.priceTable)
            }
            .background(QDTheme.ink)
        } else {
            VStack(spacing: 0) {
                warningsBannerIfNeeded
                ComposerView(model: model)
                    .padding()
                QDHairline()
                LiveResultView(model: model)
                if let runError = model.runError {
                    QDHairline()
                    Label(runError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(QDTheme.bad)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(QDTheme.ink)
        }
    }

    @ViewBuilder
    private var warningsBannerIfNeeded: some View {
        if !model.warnings.isEmpty {
            WarningsBanner(warnings: model.warnings) {
                model.warnings = []
            }
        }
    }

    // MARK: - Export

    private var exportMenu: some View {
        Menu {
            Button("Export Answer as Markdown…") {
                exportMarkdown(answerOnly: true)
            }
            .disabled(exportableRecord == nil)

            Button("Export Full Run as Markdown…") {
                exportMarkdown(answerOnly: false)
            }
            .disabled(exportableRecord == nil)

            Divider()

            // TODO(v1.x): PDF export via NSPrintOperation on the rendered answer view.
            // Stubbed disabled per spec — do not enable until it actually prints.
            Button("Export as PDF (coming soon)") {}
                .disabled(true)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help(exportableRecord == nil ? "Run the quartet (or select a past run) to export." : "Export this run")
    }

    private var exportableRecord: RunRecord? {
        model.selectedRecord ?? model.lastRecord
    }

    private func exportMarkdown(answerOnly: Bool) {
        guard let record = exportableRecord else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = answerOnly ? "quartet-answer.md" : "quartet-run.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let markdown = answerOnly
            ? MarkdownExporter.answerMarkdown(record)
            : MarkdownExporter.fullRunMarkdown(record)
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Markdown export failed: \(String(describing: error), privacy: .public)")
            exportError = error.localizedDescription
        }
    }
}

private struct WarningsBanner: View {
    let warnings: [String]
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(QDTheme.warn)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).font(.callout)
                }
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss warnings")
        }
        .padding(8)
        .background(QDTheme.warn.opacity(0.12))
    }
}

/// Public entry point used by the app target: owns the AppModel and wires
/// the main window + settings scenes together.
@MainActor
public struct QuartetDeskRoot {
    let model: AppModel

    public init() {
        self.model = AppModel()
        SmokeCapture.activateIfRequested(model: model)
    }

    public func rootView() -> some View {
        QuartetRootView(model: model)
    }

    public func settingsView() -> some View {
        QuartetSettingsView(model: model)
    }
}
