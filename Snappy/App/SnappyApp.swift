import SwiftUI

@main
struct SnappyApp: App {
    @NSApplicationDelegateAdaptor(DisplayLifecycleDelegate.self) private var lifecycleDelegate

    var body: some Scene {
        MenuBarExtra("Snappy", systemImage: "ruler") {
            MenuBarContent()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView()
        }
    }
}
