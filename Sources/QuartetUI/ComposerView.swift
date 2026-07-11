import SwiftUI
import UniformTypeIdentifiers
import AppKit
import QuartetEngine

/// Query composer: multiline text with soft-cap counter, image attach
/// (drag-drop / paste / file picker), Deliberate toggle, Run/Stop.
struct ComposerView: View {
    @Bindable var model: AppModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.queryText)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(QDTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(editorFocused ? QDTheme.ice.opacity(0.6) : QDTheme.line, lineWidth: 1))
                    .focused($editorFocused)
                    .accessibilityLabel("Query")
                if model.queryText.isEmpty {
                    Text("Ask the quartet anything — e.g. \u{201C}write me a marketing plan\u{201D}")
                        .foregroundStyle(QDTheme.text45)
                        .padding(.top, 12)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: model.composerFocusToken) { _, _ in
                // Bumped by onboarding "START MY FIRST RUN" — land the cursor
                // in the composer so the user can just type.
                editorFocused = true
            }
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }
            .onPasteCommand(of: [UTType.image.identifier, UTType.png.identifier, UTType.tiff.identifier, UTType.fileURL.identifier]) { providers in
                _ = handleDrop(providers)
            }

            HStack(spacing: 12) {
                counter

                if !model.attachments.isEmpty {
                    ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, attachment in
                        AttachmentChip(index: index, attachment: attachment) {
                            model.removeAttachment(at: index)
                        }
                    }
                }

                Button {
                    pickImageFile()
                } label: {
                    Label("Attach image", systemImage: "photo.badge.plus")
                }
                .help("Attach an image (also: drag-drop or paste into the text field)")

                Toggle("Deliberate", isOn: $model.deliberate)
                    .toggleStyle(.switch)
                    .help("Round 2: each seat sees the other answers and revises before synthesis. Off by default.")

                Spacer()

                if model.isRunning {
                    Button(role: .cancel) {
                        model.cancelRun()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(QDGhostButtonStyle(tint: QDTheme.bad))
                    // Exactly "Stop" — the live UITest queries buttons["Stop"],
                    // and textCase(.uppercase) is display-only.
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        model.startRun()
                    } label: {
                        Label("Run Quartet", systemImage: "play.fill")
                    }
                    .buttonStyle(QDPrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canRun)
                    .accessibilityLabel("Run Quartet")
                }
            }
            .controlSize(.small)

            if let attachmentError = model.attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(QDTheme.bad)
            }
        }
    }

    private var counter: some View {
        let count = model.queryText.count
        let over = count > Limits.querySoftCapCharacters
        return Text("\(count.formatted()) / \(Limits.querySoftCapCharacters.formatted())")
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(over ? QDTheme.bad : QDTheme.text45)
            .help(over ? "Over the soft cap — the run will still go through, but consider trimming." : "Character count (soft cap)")
    }

    /// One user gesture = ONE task that processes every dropped item
    /// sequentially. This keeps attachments in the order the user provided
    /// them (parallel per-file tasks complete in downscale-speed order) and
    /// keeps error accumulation deterministic. The error surface is cleared
    /// once per gesture — never per file — so no failure is silently clobbered.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let imageProviders = providers.filter {
            !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                && $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !fileProviders.isEmpty || !imageProviders.isEmpty else { return false }
        model.clearAttachmentError()
        Task { @MainActor in
            for provider in fileProviders {
                do {
                    let (name, data) = try await Self.loadFileData(from: provider)
                    await model.addAttachment(imageData: data, sourceName: name)
                } catch {
                    model.appendAttachmentError("Drop failed: \(error.localizedDescription)")
                }
            }
            for provider in imageProviders {
                do {
                    let data = try await Self.loadImageData(from: provider)
                    await model.addAttachment(imageData: data)
                } catch {
                    model.appendAttachmentError("Image drop failed: \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    private enum DropLoadError: LocalizedError {
        case notAFileURL
        case noData
        case unreadable(name: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .notAFileURL: return "The dropped item is not a file URL."
            case .noData: return "The dropped item carried no image data."
            case .unreadable(let name, let underlying):
                return "Could not read “\(name)”: \(underlying)"
            }
        }
    }

    /// Resolves a dropped file-URL provider to its BYTES, read entirely inside
    /// the `loadItem` completion. In a sandboxed app the drag's implicit
    /// sandbox extension on the URL is only guaranteed valid while the
    /// completion runs — stashing the URL and reading it later (the previous
    /// implementation) fails with a permission error once the extension is
    /// torn down. The security-scope bracket covers the flavors that ship a
    /// scoped URL; it returns false (harmlessly) for plain drag URLs.
    private static func loadFileData(from provider: NSItemProvider) async throws -> (name: String, data: Data) {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let urlData = item as? Data,
                      let url = URL(dataRepresentation: urlData, relativeTo: nil) else {
                    continuation.resume(throwing: DropLoadError.notAFileURL)
                    return
                }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    // Read NOW, on this background completion queue, while
                    // access is still valid — never after the closure returns.
                    let data = try Data(contentsOf: url)
                    continuation.resume(returning: (url.lastPathComponent, data))
                } catch {
                    continuation.resume(throwing: DropLoadError.unreadable(
                        name: url.lastPathComponent,
                        underlying: error.localizedDescription))
                }
            }
        }
    }

    private static func loadImageData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? DropLoadError.noData)
                }
            }
        }
    }

    private func pickImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        model.clearAttachmentError()
        // One task for the whole selection: deterministic order, no error clobbering.
        Task { @MainActor in
            for url in urls {
                await model.addAttachment(contentsOf: url)
            }
        }
    }
}

private struct AttachmentChip: View {
    let index: Int
    let attachment: ImageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let data = Data(base64Encoded: attachment.base64Data),
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
            }
            Text("Image \(index + 1)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(QDTheme.text60)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove image \(index + 1)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(QDTheme.panel)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(QDTheme.line, lineWidth: 1))
    }
}
