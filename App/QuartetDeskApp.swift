import SwiftUI
import QuartetUI

@main
struct QuartetDeskApp: App {
    private let root = QuartetDeskRoot()

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
