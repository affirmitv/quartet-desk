import Foundation
import os
import QuartetEngine

/// JSON-file-per-run history under ~/Library/Application Support/QuartetDesk/runs/.
public struct RunHistoryStore: Sendable {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "history")

    public let directory: URL

    /// Files that failed to decode during loadAll — surfaced, never silently skipped.
    public struct LoadResult: Sendable {
        public var records: [RunRecord]
        public var failures: [(file: String, error: String)]
    }

    public init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: true)
            self.directory = appSupport
                .appendingPathComponent("QuartetDesk", isDirectory: true)
                .appendingPathComponent("runs", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func save(_ record: RunRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        let url = fileURL(for: record.id)
        try data.write(to: url, options: .atomic)
    }

    public func loadAll() -> LoadResult {
        var records: [RunRecord] = []
        var failures: [(file: String, error: String)] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
        } catch {
            Self.logger.error("History directory listing failed: \(String(describing: error), privacy: .public)")
            return LoadResult(records: [], failures: [(directory.path, String(describing: error))])
        }

        for file in files {
            do {
                let data = try Data(contentsOf: file)
                records.append(try decoder.decode(RunRecord.self, from: data))
            } catch {
                Self.logger.error("Failed to load run \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                failures.append((file.lastPathComponent, String(describing: error)))
            }
        }

        records.sort { $0.createdAt > $1.createdAt }
        return LoadResult(records: records, failures: failures)
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
