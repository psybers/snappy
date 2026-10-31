import AppKit
import Combine
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
    private weak var mouseHandler: AnnotationMouseHandling?
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
            panel.ignoresMouseEvents = hovered == nil
        }
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
    func showTemporaryMeasurement(
        _ result: ElementDetectionResult,
        at globalPointer: Point2D,
        preferences: AppPreferences
    ) {
        let targetDisplay = connectedDisplays.first {
            $0.logicalBounds.contains(globalPointer)
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
}

enum TemporaryMeasurementOverlayContent: Equatable {
    case measurement(DetectionCandidate, Point2D, AppPreferences)
    case unavailable(Point2D, DetectionFailure, AppPreferences)
}

struct TemporaryDimensionLabels: Equatable {
    let width: String
    let height: String

    init(width: String, height: String) {
        self.width = width
        self.height = height
    }

    init(candidate: DetectionCandidate) {
        self.init(
            width: "W: \(Int(candidate.bounds.size.width.rounded())) pt",
            height: "H: \(Int(candidate.bounds.size.height.rounded())) pt"
        )
    }
}

@MainActor
final class TemporaryMeasurementOverlayView: NSView {
    private(set) var content: TemporaryMeasurementOverlayContent?
    var displayID: String?
    weak var mouseHandler: AnnotationMouseHandling?
    private var annotations: [MeasurementAnnotation] = []
    var selectionRect: Rect2D? {
        didSet { if selectionRect != oldValue { needsDisplay = true } }
    }
    private var annotationPreferences = AppPreferences.default
    var hover: AnnotationHit? {
        didSet { if hover != oldValue { needsDisplay = true } }
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
                outline.stroke()
            }
            if let text = AnnotationLayout.labelText(for: annotation.geometry),
                let rect = AnnotationLayout.labelRect(for: annotation.geometry, fontSize: fontSize)
            {
                let labelRect = NSRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height)
                let deleting = hover == .label(annotation.id)
                (deleting ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.78)).setFill()
                NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
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
        case .unavailable(let failure):
            guard failure != .captureThrottled && failure != .detectionCancelled else {
                clear()
                return
            }
            content = .unavailable(pointer, failure, preferences)
        }
        needsDisplay = true
    }

    func clear() {
        content = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        dirtyRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        drawAnnotations()
        drawSelection()
        // While the pointer is over a pinned annotation, only that item is interactive.
        switch hover == nil ? content : nil {
        case .measurement(let candidate, let pointer, let preferences):
            drawMeasurement(candidate, pointer: pointer, preferences: preferences)
        case .unavailable(let pointer, let failure, let preferences):
            drawUnavailable(pointer, failure: failure, preferences: preferences)
        case nil:
            break
        }
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
        let rect = NSRect(
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

        let labels = TemporaryDimensionLabels(candidate: candidate)
        drawLabel(
            labels.width,
            centeredAt: NSPoint(x: center.x, y: center.y + 16),
            preferences: preferences
        )
        drawLabel(
            labels.height,
            centeredAt: NSPoint(x: center.x + 40, y: center.y - 16),
            preferences: preferences
        )
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
        centeredAt point: NSPoint,
        preferences: AppPreferences
    ) {
        let font = NSFont.systemFont(ofSize: preferences.dimensionLabelFontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let labelSize = NSSize(width: textSize.width + 10, height: textSize.height + 6)
        let maxX = max(bounds.minX, bounds.maxX - labelSize.width)
        let maxY = max(bounds.minY, bounds.maxY - labelSize.height)
        let origin = NSPoint(
            x: min(max(point.x - labelSize.width / 2, bounds.minX), maxX),
            y: min(max(point.y - labelSize.height / 2, bounds.minY), maxY)
        )
        let labelRect = NSRect(origin: origin, size: labelSize)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
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
            message = "Screen Recording unavailable; check Snappy's permission and relaunch"
        case .screenCaptureFailed, .visionProcessingFailed:
            message = "Screen analysis unavailable"
        case .captureThrottled, .detectionCancelled:
            return
        default:
            message = "No reliable boundary"
        }
        drawLabel(
            message,
            centeredAt: NSPoint(x: pointer.x + 70, y: pointer.y + 24),
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
    private var latestPointer: Point2D?
    private var lastResult: ElementDetectionResult?
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
        minimumDetectionInterval: TimeInterval = 0.12
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
        lastResult = nil
        lastPointer = nil
        latestPointer = nil
        pointerGeneration += 1
        displayManager.clearTemporaryMeasurements()
    }

    private func modeChanged(_ mode: MeasurementModeState) {
        guard case .tracking(let pointer) = mode else {
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
        if latestPointer != pointer {
            latestPointer = pointer
            pointerGeneration += 1
            if lastResult != nil {
                lastResult = nil
                lastPointer = nil
                displayManager.clearTemporaryMeasurements()
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
        guard let lastResult, let lastPointer else { return }
        displayManager.showTemporaryMeasurement(
            lastResult,
            at: lastPointer,
            preferences: preferences
        )
    }
}
