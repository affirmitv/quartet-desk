import Foundation
import QuartetEngine

/// Gating + scrubbing policy for crash reporting. This module deliberately has
/// NO Sentry dependency — the SDK is linked and started only by the app target
/// (App/CrashReportingBootstrap.swift), and only when `shouldStart` says so.
///
/// Safe-by-design invariants:
/// - Default OFF: the user must explicitly opt in via Settings → Privacy.
/// - The committed Info.plist SENTRY_DSN value is the EMPTY STRING; release CI
///   injects a real DSN. Empty/missing DSN ⇒ the SDK never starts, period —
///   so a from-source build can never phone home even if the toggle is on.
/// - Content is dropped at the SOURCE, not filtered: the bootstrap's scrub
///   removes every free-form event field wholesale (message, breadcrumbs,
///   extra, context, tags, user, request, server name, fingerprint). The only
///   surviving free-form strings are exception values (the crash reason),
///   which are additionally redacted via `scrub` and length-capped. `scrub`
///   itself is best-effort pattern masking — a defense-in-depth layer, never
///   the guarantee; the guarantee comes from dropping the fields.
public enum CrashReporting {
    /// UserDefaults key for the Settings → Privacy toggle. Default false (OFF).
    public static let optInDefaultsKey = "qd.crashreports.enabled"
    /// Info.plist key whose committed value is "" (injected by release CI).
    public static let dsnInfoPlistKey = "SENTRY_DSN"

    /// The single start condition: explicit opt-in AND a non-empty DSN.
    public static func shouldStart(optIn: Bool, dsn: String?) -> Bool {
        guard optIn else { return false }
        guard let dsn, !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    public static func configuredDSN(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: dsnInfoPlistKey) as? String
    }

    public static func isOptedIn(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: optInDefaultsKey) // unset ⇒ false ⇒ OFF
    }

    /// True when this build can ever report (a DSN was injected at build time).
    /// The Privacy pane uses it to tell the user "nothing will ever be sent".
    public static func buildHasReportingEndpoint(bundle: Bundle = .main) -> Bool {
        shouldStart(optIn: true, dsn: configuredDSN(bundle: bundle))
    }

    /// Masks key-material shapes in strings that must travel with a report
    /// (exception values, log messages).
    public static func scrub(_ text: String) -> String {
        SecretRedactor.redact(text)
    }
}
