import Foundation
import os
import QuartetEngine

/// Persisted app settings (seats + price table) as JSON under
/// ~/Library/Application Support/QuartetDesk/settings.json.
/// API keys are NOT here — they live in the Keychain.
struct PersistedSettings: Codable {
    var seats: [Seat]
    var priceTable: PriceTable
}

struct SettingsStore: Sendable {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "settings")

    let fileURL: URL

    init() throws {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true)
        let dir = appSupport.appendingPathComponent("QuartetDesk", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("settings.json")
    }

    /// Returns persisted settings, or defaults on first launch.
    /// A corrupt file is surfaced via the second tuple member (never silently reset).
    func load() -> (settings: PersistedSettings, loadError: String?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return (PersistedSettings(seats: SeatConfiguration.defaultSeats(),
                                      priceTable: .bundledDefault), nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return (try JSONDecoder().decode(PersistedSettings.self, from: data), nil)
        } catch {
            Self.logger.error("Settings load failed, falling back to defaults: \(String(describing: error), privacy: .public)")
            return (PersistedSettings(seats: SeatConfiguration.defaultSeats(),
                                      priceTable: .bundledDefault),
                    "Settings file was unreadable (\(error.localizedDescription)) — defaults loaded. Saving will overwrite it.")
        }
    }

    func save(_ settings: PersistedSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
