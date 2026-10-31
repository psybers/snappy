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
            if case .rectangle(let rect) = annotation.geometry, onOutline(point, of: rect, tolerance: tolerance) {
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
        case .rectangle:
            return geometry
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
}

@MainActor
final class AnnotationInteractionController: AnnotationMouseHandling {
    private struct Drag {
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

    init(
        coordinator: MeasurementCoordinator,
        surface: AnnotationSurfacePresenting,
        preferencesStore: PreferencesStore,
        currentMeasurement: @escaping MeasurementProvider
    ) {
        self.coordinator = coordinator
        self.surface = surface
        self.preferencesStore = preferencesStore
        self.currentMeasurement = currentMeasurement
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                let point = Point2D(x: location.x, y: location.y)
                pointerMoved(toGlobal: point)
                coordinator.pointerMoved(to: point)
            }
            return event
        }
    }

    func stop() {
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
        surface.presentAnnotations(groups, preferences: preferencesStore.preferences)
        if drag == nil { refreshHover() }
    }

    // MARK: Mouse handling

    func annotationMouseDown(displayID: String, at local: Point2D) {
        guard let hit = hit(at: local, displayID: displayID) else { return }
        switch hit {
        case .label(let id):
            coordinator.removeAnnotation(id: id)
        case .body(let id):
            guard let annotation = annotation(id: id, displayID: displayID) else { return }
            if case .rectangle = annotation.geometry {
                coordinator.removeAnnotation(id: id)
                return
            }
            drag = Drag(id: id, displayID: displayID, startLocal: local, original: annotation.geometry)
        }
    }

    func annotationMouseDragged(displayID: String, at local: Point2D) {
        guard let drag, drag.displayID == displayID,
            let display = surface.connectedDisplays.first(where: { $0.id == displayID })
        else {
            return
        }
        coordinator.updateAnnotationGeometry(
            id: drag.id,
            geometry: AnnotationEditing.moved(
                drag.original,
                dx: local.x - drag.startLocal.x,
                dy: local.y - drag.startLocal.y,
                within: display.logicalBounds.size
            )
        )
    }

    func annotationMouseUp(displayID: String, at local: Point2D) {
        guard drag != nil else { return }
        drag = nil
        // mouseMoved monitors don't fire while dragging, so the cached pointer is stale.
        let location = NSEvent.mouseLocation
        lastGlobalPointer = Point2D(x: location.x, y: location.y)
        refreshHover()
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
