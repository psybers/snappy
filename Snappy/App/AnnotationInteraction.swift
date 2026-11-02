import AppKit
import Combine
import Foundation

enum AnnotationHit: Equatable {
    case label(UUID)
    case body(UUID)

    var id: UUID {
        switch self {
        case .label(let id), .body(let id):
            id
        }
    }
}

/// Geometry shared by rendering and hit testing so the two cannot disagree.
enum AnnotationLayout {
    static let hitTolerance = 5.0
    static let labelGap = 8.0

    static func labelText(for geometry: AnnotationGeometry) -> String? {
        switch geometry {
        case .horizontalMeasurement(_, let length), .verticalMeasurement(_, let length):
            "\(Int(length.rounded())) pt"
        case .rectangle(let rect):
            "\(Int(rect.size.width.rounded())) × \(Int(rect.size.height.rounded())) pt"
        case .guideline:
            nil
        }
    }

    static func guidelineDistanceLabels(
        for annotations: [MeasurementAnnotation],
        axis: AnnotationAxis,
        displayBounds: Rect2D,
        fontSize: Double,
        menuBarHeight: Double = 0
    ) -> [(region: Rect2D, text: String)] {
        let guidelines = annotations.filter { annotation in
            if case .guideline(let gAxis, _) = annotation.geometry, gAxis == axis {
                return true
            }
            return false
        }.sorted { a, b in
            guard case .guideline(_, let posA) = a.geometry,
                  case .guideline(_, let posB) = b.geometry else { return false }
            return posA < posB
        }

        guard guidelines.count >= 1 else { return [] }

        var labels: [(region: Rect2D, text: String)] = []
        let positions = guidelines.compactMap { annotation -> Double? in
            guard case .guideline(_, let position) = annotation.geometry else { return nil }
            return position
        }.sorted()

        let displaySize = axis == .horizontal ? displayBounds.size.height : displayBounds.size.width
        let edgeOffset = 10.0 // Distance from left edge for horizontal, top edge for vertical
        let labelSpacing = 5.0 // Minimum spacing between labels

        for i in 0...positions.count {
            let start: Double
            let end: Double

            if i == 0 {
                start = 0
                end = positions[0]
            } else if i == positions.count {
                start = positions[i - 1]
                end = displaySize
            } else {
                start = positions[i - 1]
                end = positions[i]
            }

            let distance = end - start
            guard distance > 1 else { continue } // Skip tiny regions

            let text = "\(Int(distance.rounded())) pt"
            let size = labelSize(for: text, fontSize: fontSize)

            var region: Rect2D
            if axis == .horizontal {
                // Horizontal guidelines (Shift+H): labels at left edge
                let centerY = (start + end) / 2
                region = Rect2D(
                    x: edgeOffset,
                    y: centerY - size.height / 2,
                    width: size.width,
                    height: size.height
                )

                // Prevent overlap with previous label
                if !labels.isEmpty {
                    let lastRegion = labels.last!.region
                    let lastMaxY = lastRegion.maxY
                    if region.minY < lastMaxY + labelSpacing {
                        // Shift this label down
                        let shift = lastMaxY + labelSpacing - region.minY
                        region = Rect2D(
                            x: region.minX,
                            y: region.minY + shift,
                            width: region.size.width,
                            height: region.size.height
                        )
                    }
                }
            } else {
                // Vertical guidelines (Shift+V): labels at top edge
                // macOS coordinates have origin at bottom-left, so top is height - offset - menuBarHeight
                let centerX = (start + end) / 2
                region = Rect2D(
                    x: centerX - size.width / 2,
                    y: displayBounds.size.height - edgeOffset - size.height - menuBarHeight,
                    width: size.width,
                    height: size.height
                )

                // Prevent overlap with previous label
                if !labels.isEmpty {
                    let lastRegion = labels.last!.region
                    let lastMaxX = lastRegion.maxX
                    if region.minX < lastMaxX + labelSpacing {
                        // Shift this label to the right
                        let shift = lastMaxX + labelSpacing - region.minX
                        region = Rect2D(
                            x: region.minX + shift,
                            y: region.minY,
                            width: region.size.width,
                            height: region.size.height
                        )
                    }
                }
            }

            labels.append((region: region, text: text))
        }

        return labels
    }

    static func labelSize(for text: String, fontSize: Double) -> Size2D {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        return Size2D(width: ceil(size.width) + 10, height: ceil(size.height) + 6)
    }

    static func labelRect(for geometry: AnnotationGeometry, fontSize: Double, displaySize: Size2D? = nil) -> Rect2D? {
        guard let text = labelText(for: geometry) else { return nil }
        let size = labelSize(for: text, fontSize: fontSize)
        switch geometry {
        case .horizontalMeasurement(let start, let length):
            return Rect2D(
                x: start.x + length / 2 - size.width / 2,
                y: start.y + labelGap,
                width: size.width,
                height: size.height
            )
        case .verticalMeasurement(let start, let length):
            return Rect2D(
                x: start.x + labelGap,
                y: start.y + length / 2 - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .rectangle(let rect):
            // Centred inside when it fits, else under the bottom edge, else inside at the bottom.
            if rect.size.width >= size.width + 2 * labelGap, rect.size.height >= size.height + 2 * labelGap {
                return Rect2D(
                    x: rect.minX + rect.size.width / 2 - size.width / 2,
                    y: rect.minY + rect.size.height / 2 - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            }
            let centredX = rect.minX + rect.size.width / 2 - size.width / 2
            let midY = rect.minY + rect.size.height / 2 - size.height / 2
            if let display = displaySize {
                // Near a side edge the label goes on the opposite side of the rectangle.
                if centredX < 0 {
                    return Rect2D(x: rect.maxX + labelGap, y: midY, width: size.width, height: size.height)
                }
                if centredX + size.width > display.width {
                    return Rect2D(
                        x: rect.minX - labelGap - size.width, y: midY, width: size.width, height: size.height)
                }
            }
            let below = rect.minY - labelGap - size.height
            if below < 0 {
                let above = rect.maxY + labelGap
                if displaySize == nil || above + size.height <= displaySize!.height {
                    return Rect2D(x: centredX, y: above, width: size.width, height: size.height)
                }
                return Rect2D(x: centredX, y: rect.minY + labelGap, width: size.width, height: size.height)
            }
            return Rect2D(x: centredX, y: below, width: size.width, height: size.height)
        case .guideline:
            return nil
        }
    }
}

enum AnnotationHitTester {
    static func onOutline(_ point: Point2D, of rect: Rect2D, tolerance: Double) -> Bool {
        let outer = Rect2D(
            x: rect.minX - tolerance,
            y: rect.minY - tolerance,
            width: rect.size.width + 2 * tolerance,
            height: rect.size.height + 2 * tolerance
        )
        guard outer.contains(point) else { return false }
        return point.x <= rect.minX + tolerance
            || point.x >= rect.maxX - tolerance
            || point.y <= rect.minY + tolerance
            || point.y >= rect.maxY - tolerance
    }

    static func hit(
        at point: Point2D,
        in annotations: [MeasurementAnnotation],
        labelFontSize: Double,
        displaySize: Size2D? = nil
    ) -> AnnotationHit? {
        let tolerance = AnnotationLayout.hitTolerance
        let newestFirst = annotations.reversed()

        for annotation in newestFirst {
            if let rect = AnnotationLayout.labelRect(for: annotation.geometry, fontSize: labelFontSize, displaySize: displaySize),
                rect.contains(point)
            {
                return .label(annotation.id)
            }
        }
        for annotation in newestFirst {
            switch annotation.geometry {
            case .horizontalMeasurement(let start, let length):
                if abs(point.y - start.y) <= tolerance,
                    point.x >= start.x - tolerance, point.x <= start.x + length + tolerance
                {
                    return .body(annotation.id)
                }
            case .verticalMeasurement(let start, let length):
                if abs(point.x - start.x) <= tolerance,
                    point.y >= start.y - tolerance, point.y <= start.y + length + tolerance
                {
                    return .body(annotation.id)
                }
            case .rectangle, .guideline:
                break
            }
        }
        for annotation in newestFirst {
            if case .rectangle(let rect) = annotation.geometry,
               rect.contains(point) || onOutline(point, of: rect, tolerance: tolerance) {
                return .body(annotation.id)
            }
        }
        for annotation in newestFirst {
            if case .guideline(let axis, let position) = annotation.geometry {
                let distance = axis == .horizontal ? abs(point.y - position) : abs(point.x - position)
                if distance <= tolerance { return .body(annotation.id) }
            }
        }
        return nil
    }
}

enum AnnotationEditing {
    /// Translates an annotation without changing its length or orientation,
    /// keeping it inside the display it belongs to.
    static func moved(
        _ geometry: AnnotationGeometry,
        dx: Double,
        dy: Double,
        within size: Size2D
    ) -> AnnotationGeometry {
        func clamp(_ value: Double, _ upper: Double) -> Double {
            min(max(value, 0), max(upper, 0))
        }
        switch geometry {
        case .horizontalMeasurement(let start, let length):
            return .horizontalMeasurement(
                start: Point2D(
                    x: clamp(start.x + dx, size.width - length),
                    y: clamp(start.y + dy, size.height)
                ),
                length: length
            )
        case .verticalMeasurement(let start, let length):
            return .verticalMeasurement(
                start: Point2D(
                    x: clamp(start.x + dx, size.width),
                    y: clamp(start.y + dy, size.height - length)
                ),
                length: length
            )
        case .guideline(let axis, let position):
            return .guideline(
                axis: axis,
                position: axis == .horizontal
                    ? clamp(position + dy, size.height)
                    : clamp(position + dx, size.width)
            )
        case .rectangle(let rect):
            return .rectangle(Rect2D(
                x: clamp(rect.minX + dx, size.width - rect.size.width),
                y: clamp(rect.minY + dy, size.height - rect.size.height),
                width: rect.size.width, height: rect.size.height
            ))
        }
    }

    /// Builds a persistent measurement from the current temporary one.
    static func pinned(
        _ axis: AnnotationAxis,
        bounds: Rect2D,
        pointerLocal: Point2D
    ) -> AnnotationGeometry {
        switch axis {
        case .horizontal:
            .horizontalMeasurement(
                start: Point2D(x: bounds.minX, y: pointerLocal.y),
                length: bounds.size.width
            )
        case .vertical:
            .verticalMeasurement(
                start: Point2D(x: pointerLocal.x, y: bounds.minY),
                length: bounds.size.height
            )
        }
    }
}

@MainActor
protocol AnnotationMouseHandling: AnyObject {
    func annotationMouseDown(displayID: String, at local: Point2D)
    func annotationMouseDragged(displayID: String, at local: Point2D)
    func annotationMouseUp(displayID: String, at local: Point2D)
    func annotationRightMouseDown(displayID: String, at local: Point2D)
}

@MainActor
protocol AnnotationSurfacePresenting: AnyObject {
    var connectedDisplays: [DisplayDescriptor] { get }
    func presentAnnotations(_ groups: [DisplayAnnotations], preferences: AppPreferences)
    func setAnnotationHover(_ hit: AnnotationHit?, onDisplay displayID: String?)
    func setAnnotationMouseHandler(_ handler: AnnotationMouseHandling?)
    func snappingCapture(for display: DisplayDescriptor) -> CapturedDisplayRegion?
}

extension AnnotationSurfacePresenting {
    func snappingCapture(for display: DisplayDescriptor) -> CapturedDisplayRegion? { nil }
}

@MainActor
final class AnnotationInteractionController: AnnotationMouseHandling {
    private struct Drag {
        let token = UUID()
        let id: UUID
        let displayID: String
        let startLocal: Point2D
        let original: AnnotationGeometry
    }

    typealias MeasurementProvider = () -> DetectionCandidate?

    private let coordinator: MeasurementCoordinator
    private let surface: AnnotationSurfacePresenting
    private let preferencesStore: PreferencesStore
    private let currentMeasurement: MeasurementProvider
    private var cancellables = Set<AnyCancellable>()
    private var groups: [DisplayAnnotations] = []
    private var drag: Drag?
    private var lastGlobalPointer: Point2D?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let snapCapturer: ScreenRegionCapturing
    private let snapFeedback: @MainActor (Double) -> Void
    private let commandHeld: @MainActor () -> Bool
    private var snapCaptureTask: Task<Void, Never>?
    private var snapImage: GuidelineSnapImage?
    private var snappedEdge: GuidelineSnapImage.Edge?
    private var latestDragPoint: Point2D?
    private var lastFeedbackTime = Date.distantPast

    init(
        coordinator: MeasurementCoordinator,
        surface: AnnotationSurfacePresenting,
        preferencesStore: PreferencesStore,
        currentMeasurement: @escaping MeasurementProvider,
        snapCapturer: ScreenRegionCapturing? = nil,
        commandHeld: @escaping @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.command) },
        snapFeedback: @escaping @MainActor (Double) -> Void = { strength in
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment, performanceTime: .now)
            // Trackpad APIs expose no amplitude control. A strong snap gets
            // a brief second pulse instead of claiming adjustable intensity.
            if strength >= 0.65 {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 70_000_000)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
        }
    ) {
        self.coordinator = coordinator
        self.surface = surface
        self.preferencesStore = preferencesStore
        self.currentMeasurement = currentMeasurement
        self.snapCapturer = snapCapturer ?? ScreenCaptureKitRegionCapturer()
        self.snapFeedback = snapFeedback
        self.commandHeld = commandHeld
    }

    func start() {
        guard cancellables.isEmpty else { return }
        surface.setAnnotationMouseHandler(self)
        coordinator.$activeSession
            .sink { [weak self] session in
                self?.sessionChanged(session)
            }
            .store(in: &cancellables)
        preferencesStore.$preferences
            .dropFirst()
            .sink { [weak self] preferences in
                guard let self else { return }
                surface.presentAnnotations(groups, preferences: preferences)
            }
            .store(in: &cancellables)
        coordinator.commands
            .sink { [weak self] command in
                self?.handle(command)
            }
            .store(in: &cancellables)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.pointerMoved(toGlobal: Point2D(x: location.x, y: location.y))
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            let location = NSEvent.mouseLocation
            let shiftHeld = event.modifierFlags.contains(.shift)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let point = Point2D(x: location.x, y: location.y)
                pointerMoved(toGlobal: point)
                coordinator.pointerMoved(to: point, shiftHeld: shiftHeld)
            }
            return event
        }
    }

    func stop() {
        clearSnapping()
        cancellables.removeAll()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        drag = nil
        surface.setAnnotationMouseHandler(nil)
        surface.setAnnotationHover(nil, onDisplay: nil)
    }

    // MARK: Creation

    func handle(_ command: MeasurementCommand) {
        switch command {
        case .pinHorizontal(let pointer):
            pin(.horizontal, at: pointer)
        case .pinVertical(let pointer):
            pin(.vertical, at: pointer)
        case .addHorizontalGuideline(let y):
            addGuideline(.horizontal, globalPosition: y)
        case .addVerticalGuideline(let x):
            addGuideline(.vertical, globalPosition: x)
        case .selectRectangle:
            break
        }
    }

    private func pin(_ axis: AnnotationAxis, at pointer: Point2D) {
        guard let measurement = currentMeasurement(),
            let displayID = measurement.displayID,
            let display = surface.connectedDisplays.first(where: { $0.id == displayID })
        else {
            return
        }
        let local = DisplayCoordinateMapper.globalToDisplayLocal(
            pointer,
            displayBounds: display.logicalBounds
        )
        guard measurement.bounds.contains(local) else { return }
        let localBounds = measurement.bounds
        let geometry = AnnotationEditing.pinned(axis, bounds: localBounds, pointerLocal: local)
        coordinator.addAnnotation(MeasurementAnnotation(displayID: displayID, geometry: geometry))
    }

    private func addGuideline(_ axis: AnnotationAxis, globalPosition: Double) {
        guard let pointer = coordinator.mode.pointer,
            let display = surface.connectedDisplays.first(where: { $0.logicalBounds.contains(pointer) })
        else {
            return
        }
        let position = axis == .horizontal
            ? globalPosition - display.logicalBounds.minY
            : globalPosition - display.logicalBounds.minX
        coordinator.addAnnotation(
            MeasurementAnnotation(
                displayID: display.id,
                geometry: .guideline(axis: axis, position: position)
            )
        )
    }

    // MARK: Hover

    func pointerMoved(toGlobal point: Point2D) {
        lastGlobalPointer = point
        guard drag == nil else { return }
        refreshHover()
    }

    private func refreshHover() {
        guard let point = lastGlobalPointer,
            let display = surface.connectedDisplays.first(where: { $0.logicalBounds.contains(point) })
        else {
            surface.setAnnotationHover(nil, onDisplay: nil)
            return
        }
        let local = DisplayCoordinateMapper.globalToDisplayLocal(point, displayBounds: display.logicalBounds)
        surface.setAnnotationHover(hit(at: local, displayID: display.id), onDisplay: display.id)
    }

    private func hit(at local: Point2D, displayID: String) -> AnnotationHit? {
        guard let group = groups.first(where: { $0.display.id == displayID }) else { return nil }
        return AnnotationHitTester.hit(
            at: local,
            in: group.annotations,
            labelFontSize: preferencesStore.preferences.dimensionLabelFontSize,
            displaySize: group.display.logicalBounds.size
        )
    }

    private func sessionChanged(_ session: MeasurementSession?) {
        groups = session?.displays ?? []
        if let drag, annotation(id: drag.id, displayID: drag.displayID) == nil {
            self.drag = nil
            clearSnapping()
        }
        surface.presentAnnotations(groups, preferences: preferencesStore.preferences)
        if drag == nil { refreshHover() }
    }

    // MARK: Mouse handling

    func annotationMouseDown(displayID: String, at local: Point2D) {
        clearSnapping()
        guard let hit = hit(at: local, displayID: displayID) else { return }
        switch hit {
        case .label(let id):
            coordinator.removeAnnotation(id: id)
        case .body(let id):
            guard let annotation = annotation(id: id, displayID: displayID) else { return }
            drag = Drag(id: id, displayID: displayID, startLocal: local, original: annotation.geometry)
            if case .guideline = annotation.geometry,
               let display = surface.connectedDisplays.first(where: { $0.id == displayID }) {
                prepareSnapping(on: display)
            }
        }
    }

    func annotationMouseDragged(displayID: String, at local: Point2D) {
        guard let drag, drag.displayID == displayID,
            let display = surface.connectedDisplays.first(where: { $0.id == displayID })
        else {
            return
        }
        latestDragPoint = local
        var geometry = AnnotationEditing.moved(
                drag.original,
                dx: local.x - drag.startLocal.x,
                dy: local.y - drag.startLocal.y,
                within: display.logicalBounds.size
            )
        if commandHeld() {
            // Release any held edge without discarding the image, so snapping
            // can resume as soon as Command is released during this drag.
            snappedEdge = nil
        } else if case .guideline(let axis, let position) = geometry, let snapImage {
            let edge = snapImage.edge(axis: axis, position: position, pointer: local,
                                      tolerance: preferencesStore.preferences.edgeTolerance.value,
                                      holding: snappedEdge)
            if let edge {
                if (snappedEdge == nil || abs(snappedEdge!.position - edge.position) > 1),
                   Date().timeIntervalSince(lastFeedbackTime) >= 0.1 {
                    snapFeedback(edge.strength)
                    lastFeedbackTime = Date()
                }
                geometry = .guideline(axis: axis, position: edge.position)
            }
            snappedEdge = edge
        }
        coordinator.updateAnnotationGeometry(id: drag.id, geometry: geometry)
    }

    func annotationMouseUp(displayID: String, at local: Point2D) {
        guard drag != nil else { return }
        clearSnapping()
        drag = nil
        // mouseMoved monitors don't fire while dragging, so the cached pointer is stale.
        let location = NSEvent.mouseLocation
        lastGlobalPointer = Point2D(x: location.x, y: location.y)
        refreshHover()
    }

    private func clearSnapping() {
        snapCaptureTask?.cancel()
        snapCaptureTask = nil
        snapImage = nil
        snappedEdge = nil
        latestDragPoint = nil
        lastFeedbackTime = .distantPast
    }

    private func prepareSnapping(on display: DisplayDescriptor) {
        if let capture = surface.snappingCapture(for: display) {
            snapImage = GuidelineSnapImage(capture)
            return
        }
        let token = drag?.token
        snapCaptureTask = Task { [weak self] in
            guard let self else { return }
            let region = Rect2D(x: 0, y: 0, width: display.logicalBounds.size.width,
                                height: display.logicalBounds.size.height)
            guard let capture = try? await snapCapturer.capture(region: region, on: display),
                  !Task.isCancelled, drag?.token == token,
                  surface.connectedDisplays.contains(display) else { return }
            snapImage = GuidelineSnapImage(capture)
            if let latestDragPoint {
                annotationMouseDragged(displayID: display.id, at: latestDragPoint)
            }
        }
    }

    func annotationRightMouseDown(displayID: String, at local: Point2D) {
        guard case .body(let id) = hit(at: local, displayID: displayID),
            let annotation = annotation(id: id, displayID: displayID),
            case .guideline = annotation.geometry
        else {
            return
        }
        coordinator.removeAnnotation(id: id)
    }

    private func annotation(id: UUID, displayID: String) -> MeasurementAnnotation? {
        groups.first(where: { $0.display.id == displayID })?
            .annotations.first(where: { $0.id == id })
    }
}

/// Narrows a detected element's bounds so pinned lines (guidelines and
/// persistent H/V measurements) act as edges, as if they were drawn on screen.
enum PinnedLineSnapper {
    static func snap(
        _ candidate: DetectionCandidate,
        pointer: Point2D,
        annotations: [MeasurementAnnotation]
    ) -> DetectionCandidate {
        guard let displayID = candidate.displayID else { return candidate }
        let epsilon = 0.5
        var minX = candidate.bounds.minX
        var maxX = candidate.bounds.maxX
        var minY = candidate.bounds.minY
        var maxY = candidate.bounds.maxY

        func vertical(_ x: Double) {
            if x > minX, x < pointer.x - epsilon { minX = x }
            if x < maxX, x > pointer.x + epsilon { maxX = x }
        }
        func horizontal(_ y: Double) {
            if y > minY, y < pointer.y - epsilon { minY = y }
            if y < maxY, y > pointer.y + epsilon { maxY = y }
        }

        for annotation in annotations where annotation.displayID == displayID {
            switch annotation.geometry {
            case .guideline(let axis, let position):
                axis == .vertical ? vertical(position) : horizontal(position)
            case .verticalMeasurement(let start, let length):
                if pointer.y >= min(start.y, start.y + length), pointer.y <= max(start.y, start.y + length) {
                    vertical(start.x)
                }
            case .horizontalMeasurement(let start, let length):
                if pointer.x >= min(start.x, start.x + length), pointer.x <= max(start.x, start.x + length) {
                    horizontal(start.y)
                }
            case .rectangle:
                break
            }
        }

        var snapped = candidate
        snapped.bounds = Rect2D(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return snapped
    }
}
