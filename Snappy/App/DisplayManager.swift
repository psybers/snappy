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
        overlayWindows[display.id]?.annotationView?.setToast("Tolerance: \(settings.level.title) (\(settings.value))")
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

enum TemporaryMeasurementOverlayContent: Equatable {
    case crosshair(Point2D, AppPreferences)
    case measurement(DetectionCandidate, Point2D, AppPreferences)
    case unavailable(Point2D, DetectionFailure, AppPreferences)
}

struct TemporaryDimensionLabels: Equatable {
    let text: String

    init(text: String) {
        self.text = text
    }

    init(candidate: DetectionCandidate) {
        self.init(
            text: "\(Int(candidate.bounds.size.width.rounded())) × \(Int(candidate.bounds.size.height.rounded())) pt"
        )
    }

    /// Prefers the bottom-right of the pointer; flips left/up when that would leave the display.
    static func origin(pointer: NSPoint, labelSize: NSSize, in bounds: NSRect, offset: CGFloat = 14) -> NSPoint {
        var x = pointer.x + offset
        if x + labelSize.width > bounds.maxX { x = pointer.x - offset - labelSize.width }
        var y = pointer.y - offset - labelSize.height
        if y < bounds.minY { y = pointer.y + offset }
        return NSPoint(
            x: min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - labelSize.width)),
            y: min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - labelSize.height))
        )
    }
}

@MainActor
final class TemporaryMeasurementOverlayView: NSView {
    private(set) var toastText: String?
    private var toastTask: Task<Void, Never>?

    func setToast(_ text: String?) {
        toastTask?.cancel()
        toastText = text
        needsDisplay = true
        guard text != nil else { return }
        toastTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) }
            catch { return }
            self?.toastText = nil
            self?.needsDisplay = true
        }
    }

    private func drawToast() {
        guard let toastText else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (toastText as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: bounds.midX - (size.width + 32) / 2,
                          y: bounds.minY + 60, width: size.width + 32, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        (toastText as NSString).draw(at: NSPoint(x: rect.minX + 16, y: rect.minY + 10),
                                   withAttributes: attributes)
    }
    private let roundRadius = 10.0
    private let bgFillAlpha = 0.6
    private(set) var content: TemporaryMeasurementOverlayContent?
    var displayID: String?
    weak var mouseHandler: AnnotationMouseHandling?
    private var annotations: [MeasurementAnnotation] = []
    var hover: AnnotationHit? {
        didSet {
            if hover != oldValue {
                needsDisplay = true
                applyCursor()
                // Leaving an annotation outside measuring: hand the cursor back.
                if hover == nil, oldValue != nil, !showsMeasureCursor { NSCursor.arrow.set() }
            }
        }
    }
    private var annotationPreferences: AppPreferences = AppPreferences()
    var selectionRect: Rect2D? {
        didSet { if selectionRect != oldValue { needsDisplay = true } }
    }
    /// Snapshot drawn beneath the overlays so on-screen video appears frozen.
    var frozenImage: CGImage? {
        didSet { needsDisplay = true }
    }
    var showsMeasureCursor = false {
        didSet { if showsMeasureCursor { applyCursor() } }
    }

    private var currentCursor: NSCursor? {
        guard let hover else { return showsMeasureCursor ? .crosshair : nil }
        guard let annotation = annotations.first(where: { $0.id == hover.id }) else { return nil }
        if case .label = hover { return .pointingHand }
        switch annotation.geometry {
        case .guideline(let axis, _):
            return axis == .horizontal ? .resizeUpDown : .resizeLeftRight
        case .rectangle:
            return .openHand
        case .horizontalMeasurement, .verticalMeasurement:
            return .openHand
        }
    }

    func applyCursor() {
        currentCursor?.set()
    }

    override func mouseMoved(with event: NSEvent) { applyCursor() }
    override func cursorUpdate(with event: NSEvent) { applyCursor() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
    }

    func setAnnotations(_ annotations: [MeasurementAnnotation], preferences: AppPreferences) {
        self.annotations = annotations
        annotationPreferences = preferences
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func localPoint(_ event: NSEvent) -> Point2D {
        let point = convert(event.locationInWindow, from: nil)
        return Point2D(x: point.x, y: point.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard let displayID else { return }
        mouseHandler?.annotationMouseDown(displayID: displayID, at: localPoint(event))
    }

    override func mouseDragged(with event: NSEvent) {
        applyCursor()
        guard let displayID else { return }
        mouseHandler?.annotationMouseDragged(displayID: displayID, at: localPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let displayID else { return }
        mouseHandler?.annotationMouseUp(displayID: displayID, at: localPoint(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let displayID else { return }
        mouseHandler?.annotationRightMouseDown(displayID: displayID, at: localPoint(event))
    }

    private func drawAnnotations() {
        let measurementColor = Self.color(from: annotationPreferences.measurementColor)
        let guidelineColor = Self.color(from: annotationPreferences.guidelineColor)
        let fontSize = annotationPreferences.dimensionLabelFontSize
        let displayBounds = Rect2D(x: 0, y: 0, width: bounds.width, height: bounds.height)

        // Draw guideline distance labels whenever guidelines are present
        // Only show labels for axes that actually have guidelines
        let hasHorizontalGuidelines = annotations.contains { annotation in
            if case .guideline(.horizontal, _) = annotation.geometry { return true }
            return false
        }
        let hasVerticalGuidelines = annotations.contains { annotation in
            if case .guideline(.vertical, _) = annotation.geometry { return true }
            return false
        }

        if hasHorizontalGuidelines {
            let menuBarHeight = NSApp.mainMenu?.menuBarHeight ?? 0
            let distanceLabels = AnnotationLayout.guidelineDistanceLabels(
                for: annotations,
                axis: .horizontal,
                displayBounds: displayBounds,
                fontSize: fontSize,
                menuBarHeight: menuBarHeight
            )
            for (region, text) in distanceLabels {
                let labelRect = NSRect(x: region.minX, y: region.minY, width: region.size.width, height: region.size.height)
                NSColor.black.withAlphaComponent(bgFillAlpha).setFill()
                NSBezierPath(roundedRect: labelRect, xRadius: roundRadius, yRadius: roundRadius).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.white,
                ]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(
                    at: NSPoint(x: labelRect.midX - size.width / 2, y: labelRect.midY - size.height / 2),
                    withAttributes: attributes
                )
            }
        }

        if hasVerticalGuidelines {
            let menuBarHeight = NSApp.mainMenu?.menuBarHeight ?? 0
            let distanceLabels = AnnotationLayout.guidelineDistanceLabels(
                for: annotations,
                axis: .vertical,
                displayBounds: displayBounds,
                fontSize: fontSize,
                menuBarHeight: menuBarHeight
            )
            for (region, text) in distanceLabels {
                let labelRect = NSRect(x: region.minX, y: region.minY, width: region.size.width, height: region.size.height)
                NSColor.black.withAlphaComponent(bgFillAlpha).setFill()
                NSBezierPath(roundedRect: labelRect, xRadius: roundRadius, yRadius: roundRadius).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.white,
                ]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(
                    at: NSPoint(x: labelRect.midX - size.width / 2, y: labelRect.midY - size.height / 2),
                    withAttributes: attributes
                )
            }
        }

        for annotation in annotations {
            let isHovered = hover?.id == annotation.id
            switch annotation.geometry {
            case .horizontalMeasurement(let start, let length):
                drawDimensionLine(
                    from: NSPoint(x: start.x, y: start.y),
                    to: NSPoint(x: start.x + length, y: start.y),
                    horizontal: true,
                    color: measurementColor,
                    lineWidth: isHovered ? 2 : 1
                )
            case .verticalMeasurement(let start, let length):
                drawDimensionLine(
                    from: NSPoint(x: start.x, y: start.y),
                    to: NSPoint(x: start.x, y: start.y + length),
                    horizontal: false,
                    color: measurementColor,
                    lineWidth: isHovered ? 2 : 1
                )
            case .guideline(let axis, let position):
                guidelineColor.setStroke()
                let line = NSBezierPath()
                line.lineWidth = isHovered ? 2 : 1
                if axis == .horizontal {
                    line.move(to: NSPoint(x: bounds.minX, y: position))
                    line.line(to: NSPoint(x: bounds.maxX, y: position))
                } else {
                    line.move(to: NSPoint(x: position, y: bounds.minY))
                    line.line(to: NSPoint(x: position, y: bounds.maxY))
                }
                line.stroke()
            case .rectangle(let rect):
                measurementColor.setStroke()
                let outline = NSBezierPath(
                    rect: NSRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height)
                )
                outline.lineWidth = isHovered ? 2 : 1
                measurementColor.withAlphaComponent(0.08).setFill()
                outline.fill()
                outline.stroke()
            }
            if let text = AnnotationLayout.labelText(for: annotation.geometry),
                let rect = AnnotationLayout.labelRect(for: annotation.geometry, fontSize: fontSize, displaySize: Size2D(width: bounds.width, height: bounds.height))
            {
                let labelRect = NSRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height)
                let deleting = hover == .label(annotation.id)
                (deleting ? NSColor.systemRed : NSColor.black.withAlphaComponent(bgFillAlpha)).setFill()
                NSBezierPath(roundedRect: labelRect, xRadius: roundRadius, yRadius: roundRadius).fill()
                let shown = deleting ? "✕" : text
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.white,
                ]
                let size = (shown as NSString).size(withAttributes: attributes)
                (shown as NSString).draw(
                    at: NSPoint(x: labelRect.midX - size.width / 2, y: labelRect.midY - size.height / 2),
                    withAttributes: attributes
                )
            }
        }
    }

    var dimensionLabels: TemporaryDimensionLabels? {
        guard case .measurement(let candidate, _, _) = content else { return nil }
        return TemporaryDimensionLabels(candidate: candidate)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }

    func update(
        _ result: ElementDetectionResult,
        pointer: Point2D,
        displayID: String,
        preferences: AppPreferences
    ) {
        switch result {
        case .detected(let candidate):
            guard candidate.isValid,
                candidate.displayID == displayID,
                candidate.bounds.minX >= 0,
                candidate.bounds.minY >= 0,
                candidate.bounds.maxX <= bounds.width,
                candidate.bounds.maxY <= bounds.height
            else {
                clear()
                return
            }
            content = .measurement(candidate, pointer, preferences)
            let target = AnimatedGeometry(
                rect: NSRect(
                    x: candidate.bounds.minX, y: candidate.bounds.minY,
                    width: candidate.bounds.size.width, height: candidate.bounds.size.height),
                pointer: NSPoint(x: pointer.x, y: pointer.y))
            animationTarget = target
            if displayedGeometry == nil { displayedGeometry = target } else { startAnimation() }
        case .unavailable(let failure):
            // Keep the previous indicator rather than blanking it on transient failures.
            guard failure != .captureThrottled && failure != .detectionCancelled else { return }
            content = .unavailable(pointer, failure, preferences)
            resetAnimation()
        }
        needsDisplay = true
    }

    func updateCrosshair(pointer: Point2D, preferences: AppPreferences) {
        resetAnimation()
        content = .crosshair(pointer, preferences)
        needsDisplay = true
    }

    private struct AnimatedGeometry {
        var rect: NSRect
        var pointer: NSPoint
    }

    private var displayedGeometry: AnimatedGeometry?
    private var animationTarget: AnimatedGeometry?
    private var animationTimer: Timer?

    private func resetAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        displayedGeometry = nil
        animationTarget = nil
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stepAnimation() {
        guard var current = displayedGeometry, let target = animationTarget else {
            resetAnimation()
            return
        }
        let factor: CGFloat = 0.5
        func ease(_ a: CGFloat, _ b: CGFloat) -> CGFloat { abs(b - a) < 0.25 ? b : a + (b - a) * factor }
        current.rect = NSRect(
            x: ease(current.rect.minX, target.rect.minX), y: ease(current.rect.minY, target.rect.minY),
            width: ease(current.rect.width, target.rect.width), height: ease(current.rect.height, target.rect.height))
        current.pointer = target.pointer
        displayedGeometry = current
        needsDisplay = true
        if current.rect == target.rect, current.pointer == target.pointer {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    func clear() {
        resetAnimation()
        content = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        dirtyRect.fill()
        NSGraphicsContext.restoreGraphicsState()
        if let frozenImage {
            NSGraphicsContext.current?.cgContext.draw(frozenImage, in: bounds)
        }

        drawAnnotations()
        drawSelection()
        // While the pointer is over a pinned annotation, only that item is interactive.
        switch hover == nil ? content : nil {
        case .crosshair(let pointer, let preferences):
            drawCrosshair(pointer: pointer, preferences: preferences)
        case .measurement(let candidate, let pointer, let preferences):
            drawMeasurement(candidate, pointer: pointer, preferences: preferences)
        case .unavailable(let pointer, let failure, let preferences):
            drawUnavailable(pointer, failure: failure, preferences: preferences)
        case nil:
            break
        }
        drawToast()
    }

    private func drawSelection() {
        guard let selection = selectionRect else { return }
        let color = Self.color(from: annotationPreferences.measurementColor)
        let rect = NSRect(x: selection.minX, y: selection.minY, width: selection.size.width, height: selection.size.height)
        color.withAlphaComponent(0.12).setFill()
        rect.fill()
        color.setStroke()
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.stroke()
    }

    private func drawMeasurement(
        _ candidate: DetectionCandidate,
        pointer: Point2D,
        preferences: AppPreferences
    ) {
        let color = Self.color(from: preferences.measurementColor)
        let rect = displayedGeometry?.rect ?? NSRect(
            x: candidate.bounds.minX,
            y: candidate.bounds.minY,
            width: candidate.bounds.size.width,
            height: candidate.bounds.size.height
        )
        let center = NSPoint(x: pointer.x, y: pointer.y)

        drawDimensionLine(
            from: NSPoint(x: rect.minX, y: center.y),
            to: NSPoint(x: rect.maxX, y: center.y),
            horizontal: true,
            color: color
        )
        drawDimensionLine(
            from: NSPoint(x: center.x, y: rect.minY),
            to: NSPoint(x: center.x, y: rect.maxY),
            horizontal: false,
            color: color
        )
        drawLabel(
            TemporaryDimensionLabels(candidate: candidate).text,
            nearPointer: center,
            preferences: preferences
        )
    }

    private func drawCrosshair(pointer: Point2D, preferences: AppPreferences) {
        Self.color(from: preferences.measurementColor).setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1
        lines.move(to: NSPoint(x: bounds.minX, y: pointer.y))
        lines.line(to: NSPoint(x: bounds.maxX, y: pointer.y))
        lines.move(to: NSPoint(x: pointer.x, y: bounds.minY))
        lines.line(to: NSPoint(x: pointer.x, y: bounds.maxY))
        lines.stroke()
    }

    private func drawDimensionLine(
        from start: NSPoint,
        to end: NSPoint,
        horizontal: Bool,
        color: NSColor,
        lineWidth: CGFloat = 1
    ) {
        color.setStroke()
        let line = NSBezierPath()
        line.lineWidth = lineWidth
        line.move(to: start)
        line.line(to: end)
        // T-shaped end caps: a perpendicular bar at each end of the line.
        let across = horizontal ? NSPoint(x: 0, y: 5) : NSPoint(x: 5, y: 0)
        for point in [start, end] {
            line.move(to: NSPoint(x: point.x - across.x, y: point.y - across.y))
            line.line(to: NSPoint(x: point.x + across.x, y: point.y + across.y))
        }
        line.stroke()
    }

    private func drawLabel(
        _ text: String,
        nearPointer pointer: NSPoint,
        preferences: AppPreferences
    ) {
        let font = NSFont.systemFont(ofSize: preferences.dimensionLabelFontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let labelSize = NSSize(width: textSize.width + 10, height: textSize.height + 6)
        let origin = TemporaryDimensionLabels.origin(pointer: pointer, labelSize: labelSize, in: bounds)
        let labelRect = NSRect(origin: origin, size: labelSize)
        NSColor.black.withAlphaComponent(bgFillAlpha).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: roundRadius, yRadius: roundRadius).fill()
        (text as NSString).draw(
            at: NSPoint(x: labelRect.minX + 5, y: labelRect.minY + 3),
            withAttributes: attributes
        )
    }

    private func drawUnavailable(
        _ pointer: Point2D,
        failure: DetectionFailure,
        preferences: AppPreferences
    ) {
        let message: String
        switch failure {
        case .accessibilityPermissionDenied:
            message = "Accessibility access unavailable"
        case .screenCapturePermissionDenied:
            return
        case .screenCaptureFailed, .visionProcessingFailed:
            message = "Screen analysis unavailable"
        case .captureThrottled, .detectionCancelled:
            return
        default:
            message = "No reliable boundary"
        }
        drawLabel(
            message,
            nearPointer: NSPoint(x: pointer.x, y: pointer.y),
            preferences: preferences
        )
    }

    private static func color(from components: ColorComponents) -> NSColor {
        NSColor(
            srgbRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.opacity
        )
    }
}

@MainActor
final class TemporaryMeasurementController {
    private let coordinator: MeasurementCoordinator
    private let detector: ElementDetecting
    private let displayManager: TemporaryMeasurementPresenting
    private let displaySource: MeasurementDisplayProviding
    private let preferencesStore: PreferencesStore
    private var cancellables = Set<AnyCancellable>()
    private var detectionTask: Task<Void, Never>?
    private var detectionTaskID: UUID?
    private var pointerGeneration = 0
    private var isMeasuringActive = false
    private var isShowingCrosshair = false
    private var latestPointer: Point2D?
    private var lastResult: ElementDetectionResult?
    private var lastTolerance: EdgeToleranceSettings?
    private(set) var lastDetectedCandidate: DetectionCandidate?
    private var lastPointer: Point2D?
    private var lastDetectionStart = Date.distantPast
    private let minimumDetectionInterval: TimeInterval

    init(
        coordinator: MeasurementCoordinator,
        detector: ElementDetecting,
        displayManager: TemporaryMeasurementPresenting,
        displaySource: MeasurementDisplayProviding,
        preferencesStore: PreferencesStore,
        minimumDetectionInterval: TimeInterval = 0.01
    ) {
        self.coordinator = coordinator
        self.detector = detector
        self.displayManager = displayManager
        self.displaySource = displaySource
        self.preferencesStore = preferencesStore
        self.minimumDetectionInterval = minimumDetectionInterval
    }

    func start() {
        guard cancellables.isEmpty else { return }
        coordinator.$mode
            .sink { [weak self] mode in
                self?.modeChanged(mode)
            }
            .store(in: &cancellables)
        preferencesStore.$preferences
            .sink { [weak self] preferences in
                self?.refreshPresentation(preferences: preferences)
            }
            .store(in: &cancellables)
    }

    func stop() {
        detectionTask?.cancel()
        detectionTask = nil
        detectionTaskID = nil
        cancellables.removeAll()
        isShowingCrosshair = false
        lastResult = nil
        lastPointer = nil
        latestPointer = nil
        pointerGeneration += 1
        displayManager.clearTemporaryMeasurements()
    }

    private func modeChanged(_ mode: MeasurementModeState) {
        let wasActive = isMeasuringActive
        isMeasuringActive = mode.isActive
        if mode.isActive, !wasActive {
            (displayManager as? DisplayManager)?.freezeScreens()
        } else if !mode.isActive, wasActive {
            (displayManager as? DisplayManager)?.unfreezeScreens()
        }
        guard case .tracking(let pointer, let shiftHeld) = mode else {
            isShowingCrosshair = false
            detectionTask?.cancel()
            detectionTask = nil
            detectionTaskID = nil
            lastResult = nil
            lastPointer = nil
            latestPointer = nil
            lastDetectedCandidate = nil
            pointerGeneration += 1
            displayManager.clearTemporaryMeasurements()
            return
        }
        if shiftHeld {
            detectionTask?.cancel()
            detectionTask = nil
            detectionTaskID = nil
            pointerGeneration += 1
            latestPointer = pointer
            isShowingCrosshair = true
            lastDetectedCandidate = nil
            displayManager.showTemporaryCrosshair(
                at: pointer, preferences: preferencesStore.preferences)
            return
        }

        if isShowingCrosshair {
            isShowingCrosshair = false
            if lastPointer == pointer, let lastResult {
                if case .detected(let candidate) = lastResult {
                    lastDetectedCandidate = candidate
                }
                displayManager.showTemporaryMeasurement(
                    lastResult, at: pointer, preferences: preferencesStore.preferences)
                return
            }
            displayManager.clearTemporaryMeasurements()
        }
        if latestPointer != pointer {
            latestPointer = pointer
            pointerGeneration += 1
            if lastResult != nil {
                lastResult = nil
                lastPointer = nil
            }
        }
        if detectionTask == nil {
            scheduleDetection()
        }
    }

    private func scheduleDetection() {
        guard detectionTask == nil, latestPointer != nil else { return }
        let taskID = UUID()
        detectionTaskID = taskID
        detectionTask = Task { [weak self] in
            guard let self else { return }
            let delay = max(
                0,
                minimumDetectionInterval - Date().timeIntervalSince(lastDetectionStart)
            )
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    finishDetectionTask(taskID)
                    return
                }
            }

            guard !Task.isCancelled,
                let pointer = latestPointer,
                coordinator.mode == .tracking(pointer: pointer),
                !displaySource.connectedDisplays.isEmpty,
                let primaryBounds = displaySource.primaryDisplayBounds
            else {
                finishDetectionTask(taskID)
                return
            }
            let generation = pointerGeneration
            lastDetectionStart = Date()
            let result = await detector.detect(
                at: pointer,
                displays: displaySource.connectedDisplays,
                primaryDisplayBounds: primaryBounds,
                now: Date()
            )
            if !Task.isCancelled,
                generation == pointerGeneration,
                coordinator.mode == .tracking(pointer: pointer)
            {
                var result = result
                if case .detected(let candidate) = result,
                    let display = displaySource.connectedDisplays.first(where: { $0.logicalBounds.contains(pointer) }),
                    let session = coordinator.activeSession
                {
                    let local = DisplayCoordinateMapper.globalToDisplayLocal(
                        pointer, displayBounds: display.logicalBounds)
                    result = .detected(PinnedLineSnapper.snap(
                        candidate, pointer: local,
                        annotations: session.displays.flatMap(\.annotations)))
                }
                lastResult = result
                lastPointer = pointer
                if case .detected(let candidate) = result {
                    lastDetectedCandidate = candidate
                }
                displayManager.showTemporaryMeasurement(
                    result,
                    at: pointer,
                    preferences: preferencesStore.preferences
                )
            }
            finishDetectionTask(taskID, afterGeneration: generation)
        }
    }

    private func finishDetectionTask(_ taskID: UUID, afterGeneration: Int? = nil) {
        guard detectionTaskID == taskID else { return }
        detectionTask = nil
        detectionTaskID = nil
        guard let afterGeneration,
            pointerGeneration != afterGeneration,
            case .tracking = coordinator.mode
        else {
            return
        }
        scheduleDetection()
    }

    private func refreshPresentation(preferences: AppPreferences) {
        let tolerance = preferences.edgeTolerance
        let changed = lastTolerance != nil && lastTolerance != tolerance
        lastTolerance = tolerance
        if changed, let pointer = coordinator.mode.pointer {
            (displayManager as? DisplayManager)?.showToleranceToast(tolerance, at: pointer)
            // A stationary pointer must be rescanned; discard results from the old threshold.
            detectionTask?.cancel()
            detectionTask = nil
            detectionTaskID = nil
            pointerGeneration += 1
            lastResult = nil
            lastPointer = nil
            lastDetectedCandidate = nil
            latestPointer = pointer
            if case .tracking(_, false) = coordinator.mode { scheduleDetection() }
        }
        if case .tracking(let pointer, true) = coordinator.mode {
            displayManager.showTemporaryCrosshair(at: pointer, preferences: preferences)
            return
        }
        guard let lastResult, let lastPointer else { return }
        displayManager.showTemporaryMeasurement(
            lastResult,
            at: lastPointer,
            preferences: preferences
        )
    }
}
