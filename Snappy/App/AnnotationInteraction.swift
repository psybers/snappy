import AppKit
import Combine
import Foundation

/// Which part of a rectangle is being manipulated: its interior/outline
/// moves it (`body`), while `resize` zones change one or two of its edges.
enum ResizeZone: Equatable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var adjustsMinX: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var adjustsMaxX: Bool { self == .right || self == .topRight || self == .bottomRight }
    var adjustsMinY: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var adjustsMaxY: Bool { self == .top || self == .topLeft || self == .topRight }
}

enum AnnotationHit: Equatable {
    case label(UUID)
    case body(UUID)
    case resize(UUID, ResizeZone)

    var id: UUID {
        switch self {
        case .label(let id), .body(let id), .resize(let id, _):
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

    /// The resize zone under `point`: within `tolerance` of an edge line and
    /// inside that edge's span (corners included, extended by `tolerance`).
    static func resizeZone(at point: Point2D, of rect: Rect2D, tolerance: Double) -> ResizeZone? {
        let withinX = point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        let withinY = point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance
        let nearLeft = abs(point.x - rect.minX) <= tolerance && withinY
        let nearRight = abs(point.x - rect.maxX) <= tolerance && withinY
        let nearBottom = abs(point.y - rect.minY) <= tolerance && withinX
        let nearTop = abs(point.y - rect.maxY) <= tolerance && withinX
        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, _, true, _): return .bottomLeft
        case (true, _, _, true): return .topLeft
        case (_, true, true, _): return .bottomRight
        case (_, true, _, true): return .topRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .bottom
        case (_, _, _, true): return .top
        default: return nil
        }
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
            if case .rectangle(let rect) = annotation.geometry {
                if let zone = resizeZone(at: point, of: rect, tolerance: tolerance) {
                    return .resize(annotation.id, zone)
                }
                if rect.contains(point) || onOutline(point, of: rect, tolerance: tolerance) {
                    return .body(annotation.id)
                }
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
    /// Rectangles never resize below this edge length.
    static let minimumRectangleDimension = 1.0

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

    /// Moves one edge of a 1D span to `moved` while the opposite edge stays
    /// fixed at `opposite`. Dragging past the opposite edge swaps their
    /// roles: the dragged edge keeps going and the span grows on the far
    /// side. The result stays within `[0, limit]` and keeps the minimum
    /// rectangle dimension.
    static func resizedSpan(moved: Double, opposite: Double, limit: Double) -> (min: Double, max: Double) {
        let minimum = minimumRectangleDimension
        let edge = min(max(moved, 0), limit)
        if edge <= opposite {
            return (min(edge, opposite - minimum), opposite)
        }
        return (opposite, max(edge, opposite + minimum))
    }

    /// Resizes a rectangle by moving the edges named by `zone`. An edge may
    /// be dragged past its opposite edge, in which case the dragged edge
    /// becomes the opposite side and the rectangle grows the other way.
    static func resized(
        _ geometry: AnnotationGeometry,
        zone: ResizeZone,
        dx: Double,
        dy: Double,
        within size: Size2D
    ) -> AnnotationGeometry {
        guard case .rectangle(let rect) = geometry else { return geometry }
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY
        if zone.adjustsMinX || zone.adjustsMaxX {
            let moved = (zone.adjustsMinX ? rect.minX : rect.maxX) + dx
            let opposite = zone.adjustsMinX ? rect.maxX : rect.minX
            let span = resizedSpan(moved: moved, opposite: opposite, limit: size.width)
            minX = span.min
            maxX = span.max
        }
        if zone.adjustsMinY || zone.adjustsMaxY {
            let moved = (zone.adjustsMinY ? rect.minY : rect.maxY) + dy
            let opposite = zone.adjustsMinY ? rect.maxY : rect.minY
            let span = resizedSpan(moved: moved, opposite: opposite, limit: size.height)
            minY = span.min
            maxY = span.max
        }
        return .rectangle(Rect2D(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
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
        /// nil moves the annotation; a zone resizes a rectangle edge/corner.
        let zone: ResizeZone?
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
    private var snappedEdges: [AnnotationAxis: GuidelineSnapImage.Edge] = [:]
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
            beginDrag(annotation, zone: nil, at: local, displayID: displayID)
        case .resize(let id, let zone):
            guard let annotation = annotation(id: id, displayID: displayID),
                  case .rectangle = annotation.geometry
            else { return }
            beginDrag(annotation, zone: zone, at: local, displayID: displayID)
        }
    }

    private func beginDrag(
        _ annotation: MeasurementAnnotation,
        zone: ResizeZone?,
        at local: Point2D,
        displayID: String
    ) {
        drag = Drag(id: annotation.id, displayID: displayID, startLocal: local,
                    original: annotation.geometry, zone: zone)
        if let display = surface.connectedDisplays.first(where: { $0.id == displayID }) {
            prepareSnapping(on: display)
        }
    }

    func annotationMouseDragged(displayID: String, at local: Point2D) {
        guard let drag, drag.displayID == displayID,
            let display = surface.connectedDisplays.first(where: { $0.id == displayID })
        else {
            return
        }
        latestDragPoint = local
        let dx = local.x - drag.startLocal.x
        let dy = local.y - drag.startLocal.y
        let geometry: AnnotationGeometry
        if let zone = drag.zone {
            geometry = AnnotationEditing.resized(
                drag.original, zone: zone, dx: dx, dy: dy,
                within: display.logicalBounds.size
            )
        } else {
            geometry = AnnotationEditing.moved(
                drag.original, dx: dx, dy: dy, within: display.logicalBounds.size
            )
        }
        var result = geometry
        if commandHeld() {
            // Release any held edges without discarding the image, so snapping
            // can resume as soon as Command is released during this drag.
            snappedEdges.removeAll()
        } else if let snapImage {
            let siblings = groups.first(where: { $0.display.id == displayID })?
                .annotations.filter { $0.id != drag.id } ?? []
            result = applySnapping(
                to: geometry, original: drag.original, pointer: local, image: snapImage,
                siblings: siblings,
                size: display.logicalBounds.size, resizeZone: drag.zone
            )
        }
        coordinator.updateAnnotationGeometry(id: drag.id, geometry: result)
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

    /// Snaps a dragged annotation to sustained visual edges in the frozen
    /// capture and to lines already on the display (guidelines and pinned
    /// measurements). Guidelines snap their position coordinate; pinned
    /// measurements snap their position coordinate and whichever end of the
    /// bar lands on a better edge along its length, so either end of a
    /// horizontal bar can align to a vertical edge and either end of a
    /// vertical bar to a horizontal edge.
    private func applySnapping(
        to geometry: AnnotationGeometry,
        original: AnnotationGeometry,
        pointer local: Point2D,
        image: GuidelineSnapImage,
        siblings: [MeasurementAnnotation],
        size: Size2D,
        resizeZone: ResizeZone?
    ) -> AnnotationGeometry {
        /// Every snap candidate for one coordinate: visual edges from the
        /// frozen capture plus pinned lines and guidelines on this display.
        func snapCandidates(axis: AnnotationAxis, position: Double) -> [GuidelineSnapImage.Edge] {
            self.snapCandidates(axis: axis, position: position, geometry: geometry,
                                siblings: siblings, size: size, pointer: local, image: image)
        }
        /// Evaluates every candidate end coordinate and returns the strongest
        /// snap, keeping track of which end it belongs to. All lookups must
        /// run before `recordSnap` updates the held edges.
        func bestEnd(
            _ axis: AnnotationAxis,
            candidates: [(position: Double, isStart: Bool)]
        ) -> (edge: GuidelineSnapImage.Edge, isStart: Bool)? {
            bestSnapEnd(axis: axis, ends: candidates, geometry: geometry,
                        siblings: siblings, size: size, pointer: local, image: image)
        }
        func clamped(_ value: Double, _ upper: Double) -> Double {
            min(max(value, 0), max(upper, 0))
        }

        switch geometry {
        case .guideline(let axis, let position):
            let pick = snapCandidates(axis: axis, position: position)
                .min { snapScore($0, position) < snapScore($1, position) }
            recordSnap(axis, pick)
            let snapped = pick?.position ?? position
            return .guideline(
                axis: axis,
                position: axis == .horizontal
                    ? clamped(snapped, size.height)
                    : clamped(snapped, size.width)
            )
        case .horizontalMeasurement(let start, let length):
            let yPick = snapCandidates(axis: .horizontal, position: start.y)
                .min { snapScore($0, start.y) < snapScore($1, start.y) }
            let xPick = bestEnd(.vertical, candidates: [
                (position: start.x, isStart: true),
                (position: start.x + length, isStart: false),
            ])
            recordSnap(.horizontal, yPick)
            recordSnap(.vertical, xPick?.edge)
            var x = start.x
            if let pick = xPick {
                x = pick.isStart ? pick.edge.position : pick.edge.position - length
            }
            return .horizontalMeasurement(
                start: Point2D(
                    x: clamped(x, size.width - length),
                    y: clamped(yPick?.position ?? start.y, size.height)
                ),
                length: length
            )
        case .verticalMeasurement(let start, let length):
            let xPick = snapCandidates(axis: .vertical, position: start.x)
                .min { snapScore($0, start.x) < snapScore($1, start.x) }
            let yPick = bestEnd(.horizontal, candidates: [
                (position: start.y, isStart: true),
                (position: start.y + length, isStart: false),
            ])
            recordSnap(.vertical, xPick)
            recordSnap(.horizontal, yPick?.edge)
            var y = start.y
            if let pick = yPick {
                y = pick.isStart ? pick.edge.position : pick.edge.position - length
            }
            return .verticalMeasurement(
                start: Point2D(
                    x: clamped(xPick?.position ?? start.x, size.width),
                    y: clamped(y, size.height - length)
                ),
                length: length
            )
        case .rectangle(let rect):
            if let resizeZone {
                return resizedRectangle(
                    zone: resizeZone, rect: rect, original: original, pointer: local,
                    image: image, siblings: siblings, size: size
                )
            }
            // Opposite sides snap independently, but the rectangle only
            // translates: whichever side finds the better edge wins per axis,
            // so dragging never resizes it.
            func bestSide(_ axis: AnnotationAxis, sides: [Double])
                -> (edge: GuidelineSnapImage.Edge, delta: Double)?
            {
                var best: (edge: GuidelineSnapImage.Edge, score: Double, delta: Double)?
                for side in sides {
                    for found in snapCandidates(axis: axis, position: side) {
                        let value = snapScore(found, side)
                        if best == nil || value < best!.score {
                            best = (found, value, found.position - side)
                        }
                    }
                }
                return best.map { ($0.edge, $0.delta) }
            }
            let xPick = bestSide(.vertical, sides: [rect.minX, rect.maxX])
            let yPick = bestSide(.horizontal, sides: [rect.minY, rect.maxY])
            recordSnap(.vertical, xPick?.edge)
            recordSnap(.horizontal, yPick?.edge)
            return .rectangle(Rect2D(
                x: clamped(rect.minX + (xPick?.delta ?? 0), size.width - rect.size.width),
                y: clamped(rect.minY + (yPick?.delta ?? 0), size.height - rect.size.height),
                width: rect.size.width,
                height: rect.size.height
            ))
        }
    }

    /// Snaps a rectangle resize: only the edges named by `zone` move, and
    /// each seeks targets on its own axis — left/right edges compete for
    /// vertical targets, top/bottom edges for horizontal ones. Untouched
    /// edges never move, and the result keeps the display/minimum-size
    /// rules from `AnnotationEditing.resized`, including dragging an edge
    /// past its opposite edge to swap sides.
    private func resizedRectangle(
        zone: ResizeZone,
        rect: Rect2D,
        original: AnnotationGeometry,
        pointer local: Point2D,
        image: GuidelineSnapImage,
        siblings: [MeasurementAnnotation],
        size: Size2D
    ) -> AnnotationGeometry {
        let geometry = AnnotationGeometry.rectangle(rect)
        guard case .rectangle(let originalRect) = original else {
            return geometry
        }
        func pick(axis: AnnotationAxis, position: Double) -> GuidelineSnapImage.Edge? {
            snapCandidates(axis: axis, position: position, geometry: geometry,
                           siblings: siblings, size: size, pointer: local, image: image)
                .min { snapScore($0, position) < snapScore($1, position) }
        }
        /// The edge that kept its drag-start coordinate is stationary; the
        /// other one is the dragged edge. They swap when the drag crosses
        /// over, so the zone alone cannot identify the dragged edge.
        func draggedIsMin(zoneAdjustsMin: Bool, fixedStart: Double,
                          currentMin: Double, currentMax: Double) -> Bool {
            if currentMin == fixedStart { return false }
            if currentMax == fixedStart { return true }
            return zoneAdjustsMin
        }
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY
        if zone.adjustsMinX || zone.adjustsMaxX {
            let fixedStart = zone.adjustsMinX ? originalRect.maxX : originalRect.minX
            let draggedMin = draggedIsMin(
                zoneAdjustsMin: zone.adjustsMinX, fixedStart: fixedStart,
                currentMin: minX, currentMax: maxX)
            let position = draggedMin ? minX : maxX
            let found = pick(axis: .vertical, position: position)
            recordSnap(.vertical, found)
            if let found {
                let span = AnnotationEditing.resizedSpan(
                    moved: found.position,
                    opposite: draggedMin ? maxX : minX,
                    limit: size.width
                )
                minX = span.min
                maxX = span.max
            }
        }
        if zone.adjustsMinY || zone.adjustsMaxY {
            let fixedStart = zone.adjustsMinY ? originalRect.maxY : originalRect.minY
            let draggedMin = draggedIsMin(
                zoneAdjustsMin: zone.adjustsMinY, fixedStart: fixedStart,
                currentMin: minY, currentMax: maxY)
            let position = draggedMin ? minY : maxY
            let found = pick(axis: .horizontal, position: position)
            recordSnap(.horizontal, found)
            if let found {
                let span = AnnotationEditing.resizedSpan(
                    moved: found.position,
                    opposite: draggedMin ? maxY : minY,
                    limit: size.height
                )
                minY = span.min
                maxY = span.max
            }
        }
        return .rectangle(Rect2D(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    /// The strongest sustained visual edge near `position` on `axis`,
    /// honouring hysteresis via the currently held edge.
    private func snapEdge(
        axis: AnnotationAxis,
        position: Double,
        pointer local: Point2D,
        image: GuidelineSnapImage
    ) -> GuidelineSnapImage.Edge? {
        image.edge(axis: axis, position: position, pointer: local,
                   tolerance: preferencesStore.preferences.edgeTolerance.value,
                   holding: snappedEdges[axis])
    }

    private func snapScore(_ found: GuidelineSnapImage.Edge, _ position: Double) -> Double {
        abs(found.position - position) / found.radius - found.strength * 0.2
    }

    /// Every snap candidate for one coordinate: visual edges from the
    /// frozen capture plus pinned lines and guidelines on this display.
    private func snapCandidates(
        axis: AnnotationAxis,
        position: Double,
        geometry: AnnotationGeometry,
        siblings: [MeasurementAnnotation],
        size: Size2D,
        pointer local: Point2D,
        image: GuidelineSnapImage
    ) -> [GuidelineSnapImage.Edge] {
        var result = annotationSnapEdges(
            axis: axis, position: position, geometry: geometry,
            siblings: siblings, size: size
        )
        if let found = snapEdge(axis: axis, position: position, pointer: local, image: image) {
            result.append(found)
        }
        return result
    }

    /// Evaluates every candidate end coordinate and returns the strongest
    /// snap, keeping track of which end it belongs to. All lookups must run
    /// before `recordSnap` updates the held edges.
    private func bestSnapEnd(
        axis: AnnotationAxis,
        ends: [(position: Double, isStart: Bool)],
        geometry: AnnotationGeometry,
        siblings: [MeasurementAnnotation],
        size: Size2D,
        pointer local: Point2D,
        image: GuidelineSnapImage
    ) -> (edge: GuidelineSnapImage.Edge, isStart: Bool)? {
        var best: (edge: GuidelineSnapImage.Edge, score: Double, isStart: Bool)?
        for end in ends {
            for found in snapCandidates(axis: axis, position: end.position, geometry: geometry,
                                        siblings: siblings, size: size,
                                        pointer: local, image: image) {
                let value = snapScore(found, end.position)
                if best == nil || value < best!.score {
                    best = (found, value, end.isStart)
                }
            }
        }
        return best.map { ($0.edge, $0.isStart) }
    }

    private func recordSnap(_ axis: AnnotationAxis, _ found: GuidelineSnapImage.Edge?) {
        if let found {
            let previous = snappedEdges[axis]
            if (previous == nil || abs(previous!.position - found.position) > 1),
               Date().timeIntervalSince(lastFeedbackTime) >= 0.1 {
                snapFeedback(found.strength)
                lastFeedbackTime = Date()
            }
        }
        snappedEdges[axis] = found
    }

    /// Fixed strength for line-to-line snaps: an exact guideline or pinned
    /// bar beats weak texture edges but yields to strong visual edges.
    private static let annotationSnapStrength = 0.65
    private static let snapOverlapEpsilon = 1.0

    /// Lines already drawn on the display (guidelines and pinned
    /// measurements) near `position` on `axis` that the dragged annotation
    /// actually crosses. Rectangles are regions, not lines, and are skipped.
    private func annotationSnapEdges(
        axis: AnnotationAxis,
        position: Double,
        geometry: AnnotationGeometry,
        siblings: [MeasurementAnnotation],
        size: Size2D
    ) -> [GuidelineSnapImage.Edge] {
        let attraction = GuidelineSnapImage.Edge(
            position: position, strength: Self.annotationSnapStrength
        ).radius
        let dragged = Self.draggedRange(geometry, axis: axis)
        var edges: [GuidelineSnapImage.Edge] = []
        for sibling in siblings {
            guard let line = Self.snapLine(for: sibling.geometry, axis: axis, size: size),
                  abs(line.position - position) <= attraction
            else { continue }
            if let dragged, !Self.rangesOverlap(dragged, line.range) { continue }
            edges.append(GuidelineSnapImage.Edge(
                position: line.position, strength: Self.annotationSnapStrength
            ))
        }
        return edges
    }

    /// A candidate target line: its fixed coordinate and its extent along
    /// the line direction, in display-local coordinates.
    private static func snapLine(
        for geometry: AnnotationGeometry,
        axis: AnnotationAxis,
        size: Size2D
    ) -> (position: Double, range: (lo: Double, hi: Double))? {
        switch geometry {
        case .guideline(let gAxis, let position):
            if axis == .vertical, gAxis == .vertical { return (position, (0, size.height)) }
            if axis == .horizontal, gAxis == .horizontal { return (position, (0, size.width)) }
            return nil
        case .verticalMeasurement(let start, let length):
            guard axis == .vertical else { return nil }
            return (start.x, (min(start.y, start.y + length), max(start.y, start.y + length)))
        case .horizontalMeasurement(let start, let length):
            guard axis == .horizontal else { return nil }
            return (start.y, (min(start.x, start.x + length), max(start.x, start.x + length)))
        case .rectangle:
            return nil
        }
    }

    /// The dragged annotation's extent along a target line's direction, used
    /// to decide whether the line visually crosses it. `nil` means the
    /// annotation spans the whole display (a guideline), so it always crosses.
    private static func draggedRange(
        _ geometry: AnnotationGeometry,
        axis: AnnotationAxis
    ) -> (lo: Double, hi: Double)? {
        switch geometry {
        case .guideline:
            return nil
        case .horizontalMeasurement(let start, let length):
            if axis == .horizontal {
                return (min(start.x, start.x + length), max(start.x, start.x + length))
            }
            return (start.y, start.y)
        case .verticalMeasurement(let start, let length):
            if axis == .vertical {
                return (min(start.y, start.y + length), max(start.y, start.y + length))
            }
            return (start.x, start.x)
        case .rectangle(let rect):
            if axis == .vertical {
                return (min(rect.minY, rect.maxY), max(rect.minY, rect.maxY))
            }
            return (min(rect.minX, rect.maxX), max(rect.minX, rect.maxX))
        }
    }

    private static func rangesOverlap(
        _ a: (lo: Double, hi: Double),
        _ b: (lo: Double, hi: Double)
    ) -> Bool {
        a.lo <= b.hi + snapOverlapEpsilon && a.hi >= b.lo - snapOverlapEpsilon
    }

    private func clearSnapping() {
        snapCaptureTask?.cancel()
        snapCaptureTask = nil
        snapImage = nil
        snappedEdges = [:]
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
