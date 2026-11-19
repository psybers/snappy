import AppKit
import ScreenCaptureKit

/// CGPreflightScreenCaptureAccess can stay false after the user grants access until relaunch,
/// so fall back to asking ScreenCaptureKit directly.
enum ScreenAccessProbe {
    @MainActor private(set) static var verified = false
    @MainActor private static var requestedThisRun = false
    @MainActor private static var checking = false

    @MainActor
    static func verify(promptIfDenied: Bool) async -> Bool {
        guard !checking else { return false }
        checking = true
        defer { checking = false }
        if CGPreflightScreenCaptureAccess() {
            verified = true
            return true
        }
        // Public APIs cannot tell an absent privacy entry from a disabled one.
        // Give macOS the first request of each run, without following its dialog
        // with our own. A persisted flag would become stale after a TCC reset.
        if promptIfDenied && !requestedThisRun {
            requestedThisRun = true
            verified = CGRequestScreenCaptureAccess()
            return verified
        }
        if (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil {
            verified = true
            return true
        }
        verified = false
        guard promptIfDenied else { return false }
        showEnableAlert()
        return false
    }

    private static var alertShowing = false

    @MainActor
    private static func showEnableAlert() {
        guard !alertShowing else { return }
        alertShowing = true
        defer { alertShowing = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Snappy needs Screen Recording access"
        alert.informativeText =
            "Enable Snappy in System Settings › Privacy & Security › Screen Recording, then press the shortcut again. You may need to relaunch Snappy."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
