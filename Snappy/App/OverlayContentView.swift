import AppKit
import Foundation

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

    /// Rounded dark pill with centered white text; every overlay label uses this.
    private func drawPill(_ text: String, in rect: NSRect, font: NSFont, fill: NSColor) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: roundRadius, yRadius: roundRadius).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawToast() {
        guard let toastText else { return }
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = (toastText as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: bounds.midX - (size.width + 32) / 2,
                          y: bounds.minY + 60, width: size.width + 32, height: size.height + 20)
        drawPill(toastText, in: rect, font: font, fill: NSColor.black.withAlphaComponent(0.85))
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
        if case .resize(_, let zone) = hover {
            switch zone {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            // AppKit exposes no public diagonal resize cursors.
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return .closedHand
            }
        }
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
        for axis in [AnnotationAxis.horizontal, .vertical] {
            guard annotations.contains(where: { annotation in
                if case .guideline(let gAxis, _) = annotation.geometry { return gAxis == axis }
                return false
            }) else { continue }
            drawGuidelineDistanceLabels(axis: axis, displayBounds: displayBounds, fontSize: fontSize)
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
                    lineWidth: strokeWidth(annotationPreferences.pinnedLineThickness, hovered: isHovered)
                )
            case .verticalMeasurement(let start, let length):
                drawDimensionLine(
                    from: NSPoint(x: start.x, y: start.y),
                    to: NSPoint(x: start.x, y: start.y + length),
                    horizontal: false,
                    color: measurementColor,
                    lineWidth: strokeWidth(annotationPreferences.pinnedLineThickness, hovered: isHovered)
                )
            case .guideline(let axis, let position):
                guidelineColor.setStroke()
                let line = NSBezierPath()
                line.lineWidth = strokeWidth(annotationPreferences.guidelineLineThickness, hovered: isHovered)
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
                let lineWidth = strokeWidth(annotationPreferences.rectangleLineThickness, hovered: isHovered)
                let rectPath = NSBezierPath(
                    rect: NSRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height)
                )
                // Outset by half the line width so the stroke lies entirely
                // outside the highlighted area instead of straddling its edge.
                let outline = NSBezierPath(
                    rect: rectPath.bounds.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
                )
                outline.lineWidth = lineWidth
                measurementColor.withAlphaComponent(0.08).setFill()
                rectPath.fill()
                outline.stroke()
            }
            if let text = AnnotationLayout.labelText(for: annotation.geometry),
                let rect = AnnotationLayout.labelRect(for: annotation.geometry, fontSize: fontSize, displaySize: Size2D(width: bounds.width, height: bounds.height))
            {
                let deleting = hover == .label(annotation.id)
                drawPill(
                    deleting ? "✕" : text,
                    in: NSRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height),
                    font: NSFont.systemFont(ofSize: fontSize),
                    fill: deleting ? NSColor.systemRed : NSColor.black.withAlphaComponent(bgFillAlpha)
                )
            }
        }
    }

    private func drawGuidelineDistanceLabels(axis: AnnotationAxis, displayBounds: Rect2D, fontSize: Double) {
        let menuBarHeight = NSApp.mainMenu?.menuBarHeight ?? 0
        let distanceLabels = AnnotationLayout.guidelineDistanceLabels(
            for: annotations,
            axis: axis,
            displayBounds: displayBounds,
            fontSize: fontSize,
            menuBarHeight: menuBarHeight
        )
        for (region, text) in distanceLabels {
            drawPill(
                text,
                in: NSRect(x: region.minX, y: region.minY, width: region.size.width, height: region.size.height),
                font: NSFont.systemFont(ofSize: fontSize),
                fill: NSColor.black.withAlphaComponent(bgFillAlpha)
            )
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
        let lineWidth = CGFloat(annotationPreferences.rectangleLineThickness)
        let outline = NSBezierPath(rect: rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
        outline.lineWidth = lineWidth
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

        let lineWidth = strokeWidth(preferences.measurementLineThickness, hovered: false)
        drawDimensionLine(
            from: NSPoint(x: rect.minX, y: center.y),
            to: NSPoint(x: rect.maxX, y: center.y),
            horizontal: true,
            color: color,
            lineWidth: lineWidth
        )
        drawDimensionLine(
            from: NSPoint(x: center.x, y: rect.minY),
            to: NSPoint(x: center.x, y: rect.maxY),
            horizontal: false,
            color: color,
            lineWidth: lineWidth
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
        lines.lineWidth = CGFloat(preferences.measurementLineThickness)
        lines.move(to: NSPoint(x: bounds.minX, y: pointer.y))
        lines.line(to: NSPoint(x: bounds.maxX, y: pointer.y))
        lines.move(to: NSPoint(x: pointer.x, y: bounds.minY))
        lines.line(to: NSPoint(x: pointer.x, y: bounds.maxY))
        lines.stroke()
    }

    private func strokeWidth(_ base: Double, hovered: Bool) -> CGFloat {
        CGFloat(base) + (hovered ? 1 : 0)
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
        // Cap half-width scales with the stroke so thicker lines keep
        // proportionally sized caps (5 pt at the default 1 pt width).
        let cap = lineWidth * 5
        let across = horizontal ? NSPoint(x: 0, y: cap) : NSPoint(x: cap, y: 0)
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
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let labelSize = NSSize(width: textSize.width + 10, height: textSize.height + 6)
        let origin = TemporaryDimensionLabels.origin(pointer: pointer, labelSize: labelSize, in: bounds)
        drawPill(
            text,
            in: NSRect(origin: origin, size: labelSize),
            font: font,
            fill: NSColor.black.withAlphaComponent(bgFillAlpha)
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
