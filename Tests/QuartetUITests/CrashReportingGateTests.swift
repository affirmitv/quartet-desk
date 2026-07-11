import XCTest
@testable import QuartetUI

/// The crash-reporting SDK must be PHYSICALLY incapable of starting unless
/// BOTH conditions hold: explicit user opt-in AND a non-empty CI-injected DSN.
final class CrashReportingGateTests: XCTestCase {
    func testEmptyDSNNeverStarts() {
        // The committed Info.plist value is "" — even an opted-in user's
        // from-source build must never start the SDK.
        XCTAssertFalse(CrashReporting.shouldStart(optIn: true, dsn: ""))
        XCTAssertFalse(CrashReporting.shouldStart(optIn: true, dsn: "   \n"))
        XCTAssertFalse(CrashReporting.shouldStart(optIn: true, dsn: nil))
    }

    func testOptOutNeverStartsEvenWithDSN() {
        XCTAssertFalse(CrashReporting.shouldStart(optIn: false, dsn: "https://k@o.ingest.example/1"))
    }

    func testStartsOnlyWithBothOptInAndDSN() {
        XCTAssertTrue(CrashReporting.shouldStart(optIn: true, dsn: "https://k@o.ingest.example/1"))
    }

    func testDefaultIsOptedOut() {
        let suiteName = "crash-gate-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(CrashReporting.isOptedIn(defaults: defaults),
                       "Crash reporting must default OFF")
    }

    func testScrubMasksKeyMaterial() {
        let scrubbed = CrashReporting.scrub("request failed for key sk-or-v1-abcdef1234567890")
        XCTAssertFalse(scrubbed.contains("sk-or-v1"))
        XCTAssertTrue(scrubbed.contains("[REDACTED]"))
    }

    func testConfiguredDSNReadsFromInfoPlistKey() {
        // The test bundle has no SENTRY_DSN — reads must come back nil/empty,
        // never a hardcoded fallback.
        let dsn = CrashReporting.configuredDSN(bundle: .main)
        XCTAssertTrue(dsn == nil || dsn!.isEmpty)
        XCTAssertFalse(CrashReporting.buildHasReportingEndpoint(bundle: .main))
    }
}
