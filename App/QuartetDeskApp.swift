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
                // Brand is dark-only in v1 (§1.2) — applied at every scene root.
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
            CommandGroup(after: .help) {
                // Re-opens the first-run tour ("Setup Assistant").
                root.welcomeCommand()
            }
        }

        Window("About Quartet Desk", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            root.settingsView()
                .preferredColorScheme(.dark)
        }
    }
}

/// CommandGroup content needs a View context to reach the openWindow action.
private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Quartet Desk") {
            openWindow(id: "about")
        }
    }
}
