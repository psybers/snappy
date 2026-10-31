import AppKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject private var persistence = SessionPersistenceController.shared
    @ObservedObject private var coordinator = MeasurementCoordinator.shared

    var body: some View {
        SettingsLink {
            Label("Preferences...", systemImage: "gearshape")
        }

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

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
