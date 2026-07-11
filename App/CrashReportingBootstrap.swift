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

    /// Strips anything that could carry prompts, answers, or key material.
    /// Crash mechanics (stack traces, exception types, OS/app version) stay;
    /// content-bearing fields are dropped or redacted.
    static func scrub(_ event: Sentry.Event) -> Sentry.Event {
        event.breadcrumbs = nil
        event.extra = nil
        event.context = nil
        if let message = event.message {
            event.message = SentryMessage(formatted: CrashReporting.scrub(message.formatted))
        }
        if let exceptions = event.exceptions {
            for exception in exceptions {
                exception.value = CrashReporting.scrub(exception.value)
            }
        }
        return event
    }
}
