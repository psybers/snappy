import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var persistence = SessionPersistenceController.shared
    @ObservedObject private var coordinator = MeasurementCoordinator.shared
    @ObservedObject private var updateChecker = UpdateChecker.shared

    var body: some View {
        if coordinator.mode.isActive {
            Button("End Measurement Mode") {
                coordinator.stop()
            }
        }

        Divider()

        Button("Restore Last Session") {
            persistence.restoreLastSession()
        }
        .disabled(!persistence.hasRestorableSession)
        .help("Reload the most recently saved annotations.")

        Button("Clear Annotations") {
            persistence.clearAnnotations()
        }
        .disabled(!persistence.hasAnnotations)
        .help("Remove all annotations from the active session.")

        Divider()

        Button {
            // Wait for menu tracking to finish before activating this menu-bar app.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                PreferencesWindowPresenter.shared.focus()
            }
        } label: {
            Label("Preferences...", systemImage: "gearshape")
        }

        Button("Check for Updates...") {
            Task { await updateChecker.checkForUpdates(manual: true) }
        }
        .disabled(updateChecker.isWorking)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
