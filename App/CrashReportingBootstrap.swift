import Foundation
import Sentry
import QuartetUI

/// Starts Sentry ONLY when CrashReporting.shouldStart passes (explicit user
/// opt-in AND a CI-injected DSN — the committed SENTRY_DSN is the empty
/// string, so from-source builds can never report). See
/// Sources/QuartetUI/CrashReporting.swift for the policy + its unit tests.
enum CrashReportingBootstrap {
    static func startIfEnabled() {
        let dsn = CrashReporting.configuredDSN()
        guard CrashReporting.shouldStart(optIn: CrashReporting.isOptedIn(), dsn: dsn) else {
            return
        }
        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            // NEVER any breadcrumbs: user content must be physically incapable
            // of riding along, not just filtered.
            options.maxBreadcrumbs = 0
            options.enableAutoSessionTracking = false
            options.beforeSend = { event in
                scrub(event)
            }
        }
    }

    /// Drop-by-default scrub. Crash MECHANICS stay (exception type, stack
    /// frames, threads, binary images, OS/app version); every field that can
    /// carry free-form content is REMOVED wholesale — not regex-filtered —
    /// because SecretRedactor is best-effort pattern matching and cannot
    /// guarantee a prompt, answer, or unrecognized credential shape is caught:
    ///   - breadcrumbs / extra / context / tags / user / request /
    ///     serverName / fingerprint: dropped entirely.
    ///   - message: dropped entirely (this app never calls captureMessage; any
    ///     SDK-generated message could embed arbitrary error text).
    ///   - exception values: the only kept free-form strings (they carry the
    ///     crash reason, e.g. "Fatal error: Index out of range"). They are
    ///     redacted AND hard-capped, limiting worst-case leakage of any
    ///     content that made it into an assertion string.
    static func scrub(_ event: Sentry.Event) -> Sentry.Event {
        event.breadcrumbs = nil
        event.extra = nil
        event.context = nil
        event.tags = nil
        event.user = nil
        event.request = nil
        event.serverName = nil
        event.fingerprint = nil
        event.message = nil
        if let exceptions = event.exceptions {
            for exception in exceptions {
                exception.value = String(CrashReporting.scrub(exception.value).prefix(300))
            }
        }
        return event
    }
}
