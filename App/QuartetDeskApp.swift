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
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
        }

        Window("About Quartet Desk", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            root.settingsView()
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
