import AppKit
import Foundation
import os
import QuartetEngine
import QuartetProviders

/// Debug-only smoke harness for non-interactive end-to-end tests.
///
/// Enabled ONLY when the app is launched with `--smoke-shots`. It listens for
/// distributed notifications (postable from a tiny CLI helper) and:
///
/// | Notification (tv.affirmi.quartetdesk.*) | object            | Action |
/// |------------------------------------------|-------------------|--------|
/// | `smoke-shot`                              | shot name         | Write PNGs of the app's own visible windows |
/// | `smoke-set-query`                         | query text        | Set the composer text (same as typing) |
/// | `smoke-run`                               | —                 | `AppModel.startRun()` — the EXACT method the Run Quartet button invokes |
/// | `smoke-tab`                               | ANSWER/PANEL/DISSENT | Switch the result tab |
/// | `smoke-settings`                          | —                 | Open the Settings window |
/// | `smoke-status`                            | —                 | Dump live run state to `smoke-shots/status.txt` |
///
/// Shots + status go to `<container>/Library/Application Support/QuartetDesk/smoke-shots/`.
///
/// Why this exists: `screencapture` / AX / XCUITest all require an unlocked
/// interactive session or TCC grants that non-interactive agents lack. An app
/// rendering its OWN view hierarchy (`NSView.cacheDisplay`) needs no permission
/// and is a faithful capture of the live window contents, even offscreen.
/// Nothing is mocked: the run triggered here goes through the real
/// orchestrator against the real APIs. No key material is ever written:
/// SecureFields render masked.
@MainActor
enum SmokeCapture {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "smoke-capture")
    private static let prefix = "tv.affirmi.quartetdesk"
    private static var observers: [NSObjectProtocol] = []
    private static weak var model: AppModel?

    /// Posted by the harness to open the Settings scene; observed in
    /// QuartetRootView (needs the SwiftUI `openSettings` environment action).
    static let openSettingsNotification = Notification.Name("\(prefix).smoke-settings")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--smoke-shots")
    }

    static func activateIfRequested(model appModel: AppModel) {
        guard isEnabled, observers.isEmpty else { return }
        model = appModel
        let center = DistributedNotificationCenter.default()

        func on(_ name: String, _ handler: @escaping @MainActor (String?) -> Void) {
            let observer = center.addObserver(forName: Notification.Name("\(prefix).\(name)"),
                                              object: nil, queue: .main) { note in
                let object = note.object as? String
                Task { @MainActor in handler(object) }
            }
            observers.append(observer)
        }

        on("smoke-shot") { name in
            capture(named: sanitized(name ?? "shot-\(Int(Date().timeIntervalSince1970))"))
        }
        on("smoke-set-query") { text in
            guard let model else { return }
            model.queryText = text ?? ""
            logger.info("Smoke: query set (\(model.queryText.count) chars)")
        }
        on("smoke-run") { _ in
            guard let model else { return }
            guard model.canRun else {
                logger.error("Smoke: startRun refused — canRun is false (running or empty query)")
                return
            }
            logger.info("Smoke: startRun()")
            model.startRun()
        }
        on("smoke-tab") { name in
            guard let model, let name, let tab = ResultTab(rawValue: name) else {
                logger.error("Smoke: unknown tab \(name ?? "nil", privacy: .public)")
                return
            }
            model.resultTab = tab
        }
        // NOTE: `smoke-settings` (open the Settings scene) is handled in
        // QuartetRootView via the SwiftUI `openSettings` environment action —
        // the legacy `showSettingsWindow:` responder selector no longer works.
        on("smoke-status") { _ in
            dumpStatus()
        }
        on("smoke-import-keys") { _ in
            importKeys()
        }

        logger.info("Smoke harness ENABLED — dir: \(shotsDirectory()?.path ?? "unavailable", privacy: .public)")
    }

    // MARK: - Key import

    /// Imports API keys from `smoke-keys.json` (inside the app's own container,
    /// written there by the test harness) into the Keychain via the SAME
    /// `KeychainStore.setKey` path the Settings UI uses, then deletes the file.
    ///
    /// Why: Keychain items created by the `security` CLI carry an
    /// `apple-tool:` partition list — a sandboxed app reading them triggers a
    /// consent prompt (errSecUserCanceled when the screen is locked). Items the
    /// app creates itself are readable without any prompt, exactly like keys
    /// pasted into Settings.
    private static func importKeys() {
        guard let dir = shotsDirectory()?.deletingLastPathComponent() else { return }
        let file = dir.appendingPathComponent("smoke-keys.json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let data = try Data(contentsOf: file)
            let keys = try JSONDecoder().decode([String: String].self, from: data)
            let store = KeychainStore()
            var imported: [String] = []
            for (providerName, key) in keys {
                guard let provider = ProviderKind(rawValue: providerName) else {
                    logger.error("Smoke key import: unknown provider \(providerName, privacy: .public)")
                    continue
                }
                try store.setKey(key, for: provider)
                imported.append(providerName)
            }
            logger.info("Smoke key import OK: \(imported.sorted().joined(separator: ","), privacy: .public)")
        } catch {
            logger.error("Smoke key import FAILED: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Status

    private static func dumpStatus() {
        guard let dir = shotsDirectory(), let model else { return }
        var lines = ["isRunning=\(model.isRunning)"]
        lines.append("synthesis=\(String(describing: model.synthesisStatus))")
        for (index, seat) in model.seatStates.enumerated() {
            lines.append("seat\(index)=\(seat.seat.modelID)|\(String(describing: seat.status))|usage=\(seat.usage.map { "\($0.inputTokens)in/\($0.outputTokens)out" } ?? "none")|chars=\(seat.text.count)")
        }
        if let record = model.lastRecord {
            lines.append("record.cost=\(String(format: "%.5f", record.cost.knownUSD))")
            lines.append("record.unpriced=\(record.cost.unknownModels.joined(separator: ","))")
            lines.append("record.answerChars=\(record.synthesizedAnswer?.count ?? 0)")
            lines.append("record.dissent=\(String(describing: record.dissent))")
        }
        if let error = model.runError { lines.append("runError=\(error)") }
        do {
            try Data(lines.joined(separator: "\n").utf8)
                .write(to: dir.appendingPathComponent("status.txt"), options: .atomic)
        } catch {
            logger.error("Smoke status write failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Capture

    private static func sanitized(_ name: String) -> String {
        String(name.unicodeScalars.filter { CharacterSet.alphanumerics.union(.init(charactersIn: "-_.")).contains($0) })
    }

    private static func shotsDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("QuartetDesk/smoke-shots", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            logger.error("Smoke shots dir creation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func capture(named name: String) {
        guard let dir = shotsDirectory() else { return }
        let ordered = ([NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.windows)
        var seen = Set<ObjectIdentifier>()
        var index = 0
        for window in ordered where window.isVisible {
            guard seen.insert(ObjectIdentifier(window)).inserted else { continue }
            // contentView.superview is the theme frame — includes the title bar
            // and toolbar, so the shot looks like the real window.
            guard let view = window.contentView?.superview ?? window.contentView else {
                logger.error("Smoke shot \(name, privacy: .public): window has no content view")
                continue
            }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                logger.error("Smoke shot \(name, privacy: .public): bitmap rep failed")
                continue
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                logger.error("Smoke shot \(name, privacy: .public): PNG encode failed")
                continue
            }
            let filename = index == 0 ? "\(name).png" : "\(name)-w\(index).png"
            do {
                try data.write(to: dir.appendingPathComponent(filename), options: .atomic)
                logger.info("Smoke shot written: \(filename, privacy: .public)")
            } catch {
                logger.error("Smoke shot \(name, privacy: .public) write failed: \(String(describing: error), privacy: .public)")
            }
            index += 1
        }
        if index == 0 {
            logger.error("Smoke shot \(name, privacy: .public): no visible windows captured")
        }
    }
}
