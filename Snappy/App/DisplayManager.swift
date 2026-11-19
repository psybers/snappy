import AppKit
import Combine
import ScreenCaptureKit
import CoreGraphics

struct DisplayAnnotationRegistry {
    private(set) var groupsByDisplayID: [String: DisplayAnnotations] = [:]
    private(set) var connectedDisplayIDs: Set<String> = []

    var unavailableGroups: [DisplayAnnotations] {
        groupsByDisplayID.values
            .filter { !connectedDisplayIDs.contains($0.display.id) }
            .sorted { $0.display.id < $1.display.id }
    }

    mutating func replaceGroups(_ groups: [DisplayAnnotations]) {
        groupsByDisplayID = Dictionary(
            groups.map { ($0.display.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    mutating func reconcileConnectedDisplays(_ displays: [DisplayDescriptor]) {
        connectedDisplayIDs = Set(displays.filter(\.isValid).map(\.id))
    }
}

@MainActor
protocol TemporaryMeasurementPresenting: AnyObject {
    func showTemporaryMeasurement(
        _ result: ElementDetectionResult,
        at globalPointer: Point2D,
        preferences: AppPreferences
    )
    func showTemporaryCrosshair(at globalPointer: Point2D, preferences: AppPreferences)
    func clearTemporaryMeasurements()
    func freezeScreens()
    func unfreezeScreens()
    func showToleranceToast(_ settings: EdgeToleranceSettings, at pointer: Point2D)
}

extension TemporaryMeasurementPresenting {
    func freezeScreens() {}
    func unfreezeScreens() {}
    func showToleranceToast(_ settings: EdgeToleranceSettings, at pointer: Point2D) {}
}

@MainActor
protocol MeasurementDisplayProviding: TemporaryMeasurementPresenting {
    var connectedDisplays: [DisplayDescriptor] { get }
    var primaryDisplayBounds: Rect2D? { get }
}

@MainActor
final class DisplayManager: ObservableObject, MeasurementDisplayProviding, AnnotationSurfacePresenting, SelectionSurfacePresenting {
    static let shared = DisplayManager()

    @Published private(set) var connectedDisplays: [DisplayDescriptor] = []
    @Published private(set) var annotationRegistry = DisplayAnnotationRegistry()

    private var overlayWindows: [String: ScreenOverlayPanel] = [:]

    func snappingCapture(for display: DisplayDescriptor) -> CapturedDisplayRegion? {
        guard let image = overlayWindows[display.id]?.annotationView?.frozenImage else { return nil }
        return CapturedDisplayRegion(image: image, displayID: display.id,
            displayLocalBounds: Rect2D(x: 0, y: 0, width: display.logicalBounds.size.width,
                                       height: display.logicalBounds.size.height))
    }

    func showToleranceToast(_ settings: EdgeToleranceSettings, at pointer: Point2D) {
        guard let display = connectedDisplays.first(where: { $0.logicalBounds.contains(pointer) }) else { return }
        for panel in overlayWindows.values { panel.annotationView?.setToast(nil) }
        let text = settings.temporaryValue != nil
            ? "Tolerance: \(settings.value) (temporary)"
            : "Tolerance: \(settings.level.title) (\(settings.value))"
        overlayWindows[display.id]?.annotationView?.setToast(text)
    }
    private weak var mouseHandler: AnnotationMouseHandling?
    private var capturesMouse = false
    fileprivate var freezeGeneration = 0
    private var screenChangeObserver: NSObjectProtocol?

    var primaryDisplayBounds: Rect2D? {
        let primaryID = "cgdisplay-\(CGMainDisplayID())"
        return connectedDisplays.first(where: { $0.id == primaryID })?.logicalBounds
    }

    func start() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDisplays()
            }
        }
        refreshDisplays()
    }

    func stop() {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        overlayWindows.values.forEach { $0.close() }
        overlayWindows.removeAll()
        connectedDisplays = []
        annotationRegistry.reconcileConnectedDisplays([])
    }

    func replaceAnnotationGroups(_ groups: [DisplayAnnotations]) {
        annotationRegistry.replaceGroups(groups)
        annotationRegistry.reconcileConnectedDisplays(connectedDisplays)
    }

    func presentAnnotations(_ groups: [DisplayAnnotations], preferences: AppPreferences) {
        for (displayID, panel) in overlayWindows {
            panel.annotationView?.setAnnotations(
                groups.first(where: { $0.display.id == displayID })?.annotations ?? [],
                preferences: preferences
            )
        }
    }

    func setAnnotationHover(_ hit: AnnotationHit?, onDisplay displayID: String?) {
        for (id, panel) in overlayWindows {
            let hovered = id == displayID ? hit : nil
            panel.annotationView?.hover = hovered
            panel.ignoresMouseEvents = hovered == nil && !capturesMouse
            // Re-assert the cursor on every pointer move; the system resets it otherwise.
            if hovered != nil { panel.annotationView?.applyCursor() }
        }
    }

    var isHoveringAnnotation: Bool {
        overlayWindows.values.contains { $0.annotationView?.hover != nil }
    }

    /// While measuring, the overlays take mouse events so they never reach the app underneath.
    func setCapturesMouse(_ requested: Bool) {
        // Without Screen Recording access the system permission dialog must stay clickable.
        let captures = requested && (CGPreflightScreenCaptureAccess() || ScreenAccessProbe.verified)
        capturesMouse = captures
        for panel in overlayWindows.values {
            panel.ignoresMouseEvents = !captures && panel.annotationView?.hover == nil
            panel.annotationView?.showsMeasureCursor = captures
        }
        if !captures { NSCursor.arrow.set() }
    }

    func setSelectionRect(_ globalRect: Rect2D?) {
        for (id, panel) in overlayWindows {
            guard let globalRect,
                let display = connectedDisplays.first(where: { $0.id == id }),
                let clipped = SelectionGeometry.clip(globalRect, to: display.logicalBounds)
            else {
                panel.annotationView?.selectionRect = nil
                continue
            }
            panel.annotationView?.selectionRect = DisplayCoordinateMapper.globalToDisplayLocal(
                clipped,
                displayBounds: display.logicalBounds
            )
        }
    }

    func setAnnotationMouseHandler(_ handler: AnnotationMouseHandling?) {
        mouseHandler = handler
        overlayWindows.values.forEach { $0.annotationView?.mouseHandler = handler }
    }

    func clearTemporaryMeasurements() {
        overlayWindows.values.forEach { $0.clearTemporaryMeasurement() }
    }

    func refreshDisplays() {
        let screens = NSScreen.screens
        var descriptors: [DisplayDescriptor] = []
        var currentIDs = Set<String>()

        for screen in screens {
            guard let descriptor = Self.descriptor(for: screen), descriptor.isValid else { continue }
            descriptors.append(descriptor)
            currentIDs.insert(descriptor.id)

            let panel: ScreenOverlayPanel
            if let existing = overlayWindows[descriptor.id] {
                panel = existing
                panel.setFrame(screen.frame, display: true)
            } else {
                panel = ScreenOverlayPanel(frame: screen.frame)
                overlayWindows[descriptor.id] = panel
            }
            panel.annotationView?.displayID = descriptor.id
            panel.ignoresMouseEvents = !capturesMouse
            panel.annotationView?.showsMeasureCursor = capturesMouse
            panel.annotationView?.mouseHandler = mouseHandler
            panel.orderFrontRegardless()
        }

        let removedIDs = overlayWindows.keys.filter { !currentIDs.contains($0) }
        for removedID in removedIDs {
            overlayWindows.removeValue(forKey: removedID)?.close()
        }

        connectedDisplays = descriptors
        clearTemporaryMeasurements()
        annotationRegistry.reconcileConnectedDisplays(descriptors)
    }

    static func descriptor(for screen: NSScreen) -> DisplayDescriptor? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        return DisplayDescriptor(
            id: "cgdisplay-\(displayID)",
            logicalBounds: Rect2D(
                x: screen.frame.origin.x,
                y: screen.frame.origin.y,
                width: screen.frame.width,
                height: screen.frame.height
            ),
            pixelWidth: Int(CGDisplayPixelsWide(displayID)),
            pixelHeight: Int(CGDisplayPixelsHigh(displayID)),
            backingScale: screen.backingScaleFactor
        )
    }
}

extension DisplayManager {
    static func captureDisplayImage(
        _ displayID: UInt32,
        from content: SCShareableContent
    ) async throws -> CGImage {
        guard let display = content.displays.first(where: {
            $0.displayID == displayID
        }) else {
            throw ScreenCaptureError.displayUnavailable
        }

        // Exclude only the annotation/frozen-screen overlays. Other Snappy
        // windows, including Preferences, should remain part of the capture.
        let overlayWindowIDs = Set(NSApp.windows.compactMap { window -> CGWindowID? in
            guard window is ScreenOverlayPanel, window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })
        let filter = SCContentFilter(
            display: display,
            excludingWindows: content.windows.filter {
                overlayWindowIDs.contains($0.windowID)
            }
        )

        let configuration = SCScreenshotConfiguration()

        // Request the native display pixel resolution.
        let scale = CGFloat(filter.pointPixelScale)

        configuration.width = Int(
            (filter.contentRect.width * scale).rounded()
        )

        configuration.height = Int(
            (filter.contentRect.height * scale).rounded()
        )

        // Preserve OS-rendered window shadows.
        configuration.ignoreShadows = false

        // Don't include the mouse cursor in the frozen image.
        configuration.showsCursor = false

        // Optimize the image for presentation on this display.
        configuration.displayIntent = .local
        configuration.dynamicRange = .sdr

        let output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter,
            configuration: configuration
        )

        guard let image = output.sdrImage else {
            throw ScreenCaptureError.captureReturnedNoImage
        }

        return image
    }

    /// Captures every display (excluding this app's overlays) and shows the
    /// result beneath the overlays until `unfreezeScreens()`.
    func freezeScreens() {
        freezeGeneration += 1
        let generation = freezeGeneration
        let displays = connectedDisplays

        Task { [weak self] in
            guard let self else { return }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )

                var capturedImages: [(displayID: String, image: CGImage)] = []

                for display in displays {
                    guard display.isValid,
                          display.id.hasPrefix("cgdisplay-"),
                          let cgDisplayID = UInt32(
                              display.id.dropFirst("cgdisplay-".count)
                          )
                    else {
                        continue
                    }

                    let image = try await DisplayManager.captureDisplayImage(
                        cgDisplayID,
                        from: content
                    )

                    capturedImages.append((display.id, image))
                }

                // Ignore results from an older freeze operation.
                guard freezeGeneration == generation else {
                    return
                }

                // Don't freeze only part of the desktop.
                let validDisplayCount = displays.filter(\.isValid).count

                guard capturedImages.count == validDisplayCount else {
                    NSLog("Failed to capture all displays for freeze")
                    return
                }

                // Apply all images only after every capture succeeds.
                for (displayID, image) in capturedImages {
                    overlayWindows[displayID]?.annotationView?.frozenImage = image
                }

            } catch {
                NSLog(
                    "Failed to freeze screens: %@",
                    error.localizedDescription
                )
            }
        }
    }

    func unfreezeScreens() {
        for panel in overlayWindows.values { panel.annotationView?.setToast(nil) }
        freezeGeneration += 1
        for panel in overlayWindows.values { panel.annotationView?.frozenImage = nil }
    }

    func showTemporaryMeasurement(
        _ result: ElementDetectionResult,
        at globalPointer: Point2D,
        preferences: AppPreferences
    ) {
        let targetDisplay = connectedDisplays.first {
            $0.logicalBounds.contains(globalPointer)
        }
        if case .unavailable(.screenCapturePermissionDenied) = result, capturesMouse {
            setCapturesMouse(false)
        }
        for (displayID, panel) in overlayWindows {
            guard let display = connectedDisplays.first(where: { $0.id == displayID }),
                  display.id == targetDisplay?.id
            else {
                panel.clearTemporaryMeasurement()
                continue
            }
            panel.showTemporaryMeasurement(
                result,
                pointer: DisplayCoordinateMapper.globalToDisplayLocal(
                    globalPointer,
                    displayBounds: display.logicalBounds
                ),
                displayID: displayID,
                preferences: preferences
            )
        }
    }

    func showTemporaryCrosshair(at globalPointer: Point2D, preferences: AppPreferences) {
        for (displayID, panel) in overlayWindows {
            guard let display = connectedDisplays.first(where: { $0.id == displayID }),
                display.logicalBounds.contains(globalPointer)
            else {
                panel.clearTemporaryMeasurement()
                continue
            }
            panel.annotationView?.updateCrosshair(
                pointer: DisplayCoordinateMapper.globalToDisplayLocal(
                    globalPointer, displayBounds: display.logicalBounds),
                preferences: preferences
            )
        }
    }
}
