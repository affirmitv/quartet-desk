import SwiftUI
import QuartetUI

@main
struct QuartetDeskApp: App {
    private let root = QuartetDeskRoot()

    init() {
        // No-op unless the user opted in AND release CI injected a DSN
        // (the committed SENTRY_DSN is ""). See CrashReportingBootstrap.
        CrashReportingBootstrap.startIfEnabled()
    }

    var body: some Scene {
        WindowGroup {
            root.rootView()
                .frame(minWidth: 980, minHeight: 640)
        }

        Settings {
            root.settingsView()
        }
    }
}
