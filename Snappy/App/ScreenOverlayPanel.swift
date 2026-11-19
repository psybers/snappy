import AppKit
import Foundation

enum CursorOverride {
    private static var enabled = false

    /// Lets this background (accessory) app set the cursor while its overlays are under the pointer.
    static func enableInBackground() {
        guard !enabled else { return }
        enabled = true
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
            let connSym = dlsym(handle, "CGSDefaultConnectionForThread"),
            let setSym = dlsym(handle, "CGSSetConnectionProperty")
        else {
            return
        }
        let connection = unsafeBitCast(connSym, to: DefaultConnection.self)()
        _ = unsafeBitCast(setSym, to: SetProperty.self)(
            connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

@MainActor
final class ScreenOverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        CursorOverride.enableInBackground()
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let overlayView = TemporaryMeasurementOverlayView(
            frame: NSRect(origin: .zero, size: frame.size)
        )
        overlayView.autoresizingMask = [.width, .height]
        contentView = overlayView
    }

    func showTemporaryMeasurement(
        _ result: ElementDetectionResult,
        pointer: Point2D,
        displayID: String,
        preferences: AppPreferences
    ) {
        (contentView as? TemporaryMeasurementOverlayView)?.update(
            result,
            pointer: pointer,
            displayID: displayID,
            preferences: preferences
        )
    }

    func clearTemporaryMeasurement() {
        (contentView as? TemporaryMeasurementOverlayView)?.clear()
    }

    var annotationView: TemporaryMeasurementOverlayView? {
        contentView as? TemporaryMeasurementOverlayView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
