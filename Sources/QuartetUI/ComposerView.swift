import SwiftUI
import UniformTypeIdentifiers
import AppKit
import QuartetEngine

/// Query composer: multiline text with soft-cap counter, image attach
/// (drag-drop / paste / file picker), Deliberate toggle, Run/Stop.
struct ComposerView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.queryText)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                if model.queryText.isEmpty {
                    Text("Ask the quartet anything — e.g. \u{201C}write me a marketing plan\u{201D}")
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
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
                } else {
                    Button {
                        model.startRun()
                    } label: {
                        Label("Run Quartet", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canRun)
                }
            }
            .controlSize(.small)

            if let attachmentError = model.attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var counter: some View {
        let count = model.queryText.count
        let over = count > Limits.querySoftCapCharacters
        return Text("\(count.formatted()) / \(Limits.querySoftCapCharacters.formatted())")
            .font(.caption.monospacedDigit())
            .foregroundStyle(over ? .red : .secondary)
            .help(over ? "Over the soft cap — the run will still go through, but consider trimming." : "Character count (soft cap)")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    if let error {
                        Task { @MainActor in model.attachmentError = "Drop failed: \(error.localizedDescription)" }
                        return
                    }
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        do {
                            let fileData = try Data(contentsOf: url)
                            await model.addAttachment(imageData: fileData)
                        } catch {
                            model.attachmentError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    Task { @MainActor in
                        if let data {
                            await model.addAttachment(imageData: data)
                        } else {
                            model.attachmentError = "Image drop failed: \(error?.localizedDescription ?? "no data")"
                        }
                    }
                }
            }
        }
        return handled
    }

    private func pickImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            Task { @MainActor in
                do {
                    let data = try Data(contentsOf: url)
                    await model.addAttachment(imageData: data)
                } catch {
                    model.attachmentError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
                }
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
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
    }
}
