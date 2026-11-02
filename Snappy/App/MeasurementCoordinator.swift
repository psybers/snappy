import Combine
import Foundation

enum MeasurementModeState: Equatable {
    case inactive
    case tracking(pointer: Point2D, shiftHeld: Bool = false)
    case selecting(start: Point2D, current: Point2D)

    var isActive: Bool {
        if case .inactive = self { return false }
        return true
    }

    var pointer: Point2D? {
        switch self {
        case .inactive:
            nil
        case .tracking(let pointer, _):
            pointer
        case .selecting(_, let current):
            current
        }
    }

    var shiftHeld: Bool {
        switch self {
        case .inactive:
            false
        case .tracking(_, let shiftHeld):
            shiftHeld
        case .selecting:
            false
        }
    }
}

enum MeasurementCommand: Equatable {
    case pinHorizontal(at: Point2D)
    case pinVertical(at: Point2D)
    case addHorizontalGuideline(y: Double)
    case addVerticalGuideline(x: Double)
    case selectRectangle(Rect2D)
}

@MainActor
final class MeasurementCoordinator: ObservableObject {
    static let shared = MeasurementCoordinator()

    @Published private(set) var mode: MeasurementModeState = .inactive
    @Published private(set) var activeSession: MeasurementSession?
    private(set) var keepsAnnotationsOnExit = false

    let commands = PassthroughSubject<MeasurementCommand, Never>()
    let toleranceAdjustments = PassthroughSubject<Int, Never>()

    private var ignoresActivationShift = false

    private let moveCursor: @MainActor (Point2D, Double, Double) -> Point2D?

    init(moveCursor: @escaping @MainActor (Point2D, Double, Double) -> Point2D? = GlobalInputMonitor.moveCursor) {
        self.moveCursor = moveCursor
    }

    func startFreshSession(
        displays: [DisplayDescriptor],
        pointer: Point2D,
        shiftHeldAtActivation: Bool = false
    ) {
        ignoresActivationShift = shiftHeldAtActivation
        let validDisplays = displays.filter(\.isValid)
        // Annotations already on screen (e.g. after Restore Last Session) stay in place.
        if let existing = activeSession, existing.annotationCount > 0 {
            mode = .tracking(pointer: pointer, shiftHeld: false)
            return
        }
        activeSession = MeasurementSession(
            displays: validDisplays.map {
                DisplayAnnotations(display: $0, annotations: [])
            }
        )
        mode = .tracking(pointer: pointer, shiftHeld: false)
    }

    func stop(keepingAnnotations: Bool = false) {
        guard mode.isActive else { return }
        keepsAnnotationsOnExit = keepingAnnotations
        mode = .inactive
    }

    func restore(_ session: MeasurementSession, displays: [DisplayDescriptor]) {
        var restored = session
        restored.displays = SessionRemapper.remap(session.displays, connected: displays)
        restored.lastModifiedAt = Date()
        activeSession = restored
    }

    func remapSession(to displays: [DisplayDescriptor]) {
        guard var session = activeSession else { return }
        let remapped = SessionRemapper.remap(session.displays, connected: displays)
        guard remapped != session.displays else { return }
        session.displays = remapped
        activeSession = session
    }

    func clearAnnotations() {
        guard var session = activeSession, session.annotationCount > 0 else { return }
        for index in session.displays.indices {
            session.displays[index].annotations.removeAll()
        }
        session.lastModifiedAt = Date()
        activeSession = session
    }

    func addAnnotation(_ annotation: MeasurementAnnotation) {
        guard var session = activeSession,
            let index = session.displays.firstIndex(where: { $0.display.id == annotation.displayID })
        else {
            return
        }
        session.displays[index].annotations.append(annotation)
        session.lastModifiedAt = Date()
        activeSession = session
    }

    func updateAnnotationGeometry(id: UUID, geometry: AnnotationGeometry) {
        guard var session = activeSession else { return }
        for displayIndex in session.displays.indices {
            if let index = session.displays[displayIndex].annotations.firstIndex(where: { $0.id == id }) {
                session.displays[displayIndex].annotations[index].geometry = geometry
                session.lastModifiedAt = Date()
                activeSession = session
                return
            }
        }
    }

    func removeAnnotation(id: UUID) {
        guard var session = activeSession else { return }
        for displayIndex in session.displays.indices {
            let before = session.displays[displayIndex].annotations.count
            session.displays[displayIndex].annotations.removeAll { $0.id == id }
            if session.displays[displayIndex].annotations.count != before {
                session.lastModifiedAt = Date()
                activeSession = session
                return
            }
        }
    }

    func pointerMoved(to point: Point2D, shiftHeld: Bool? = nil) {
        guard point.isFinite else { return }
        let shiftHeld = shiftHeld.map { effectiveShiftState($0) }
        switch mode {
        case .inactive:
            break
        case .tracking(let currentPointer, let currentShift):
            if currentPointer != point || (shiftHeld ?? currentShift) != currentShift {
                mode = .tracking(pointer: point, shiftHeld: shiftHeld ?? currentShift)
            }
        case .selecting(let start, _):
            mode = .selecting(start: start, current: point)
        }
    }

    private func effectiveShiftState(_ shiftHeld: Bool) -> Bool {
        // The Shift in the activation chord must be released before crosshair mode is armed.
        if !shiftHeld { ignoresActivationShift = false }
        return shiftHeld && !ignoresActivationShift
    }

    func updateShiftState(_ shiftHeld: Bool) {
        guard mode.isActive else { return }
        let shiftHeld = effectiveShiftState(shiftHeld)
        // Only update shift state without triggering pointer movement
        if case .tracking(let pointer, let currentShift) = mode, currentShift != shiftHeld {
            mode = .tracking(pointer: pointer, shiftHeld: shiftHeld)
        }
    }

    func leftMouseDown(at point: Point2D) {
        guard mode.isActive, point.isFinite else { return }
        mode = .selecting(start: point, current: point)
    }

    func leftMouseUp(at point: Point2D) {
        guard case .selecting(let start, _) = mode,
              point.isFinite
        else {
            return
        }

        mode = .tracking(pointer: point)
        let selection = Rect2D(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        guard selection.isNonEmpty else { return }
        commands.send(.selectRectangle(selection))
    }

    func keyDown(key: String, keyCode: UInt16, modifiers: Set<ShortcutModifier>) {
        guard mode.isActive else { return }
        if modifiers.isEmpty {
            switch key.lowercased() {
            case "t": toleranceAdjustments.send(0); return
            case "-": toleranceAdjustments.send(-1); return
            case "=": toleranceAdjustments.send(1); return
            default: break
            }
        }
        if keyCode == 53 {
            stop()
            return
        }
        if (123...126).contains(keyCode), modifiers.isEmpty || modifiers == [.shift] {
            guard case .tracking(let pointer, _) = mode else { return }
            let step = modifiers.contains(.shift) ? 10.0 : 1.0
            let dx = keyCode == 123 ? -step : keyCode == 124 ? step : 0
            let dy = keyCode == 125 ? -step : keyCode == 126 ? step : 0
            if let moved = moveCursor(pointer, dx, dy) {
                pointerMoved(to: moved, shiftHeld: modifiers.contains(.shift))
            }
            return
        }
        guard let pointer = mode.pointer else { return }
        let character = key.lowercased()
        if character == "h", modifiers.isEmpty {
            commands.send(.pinHorizontal(at: pointer))
        } else if character == "v", modifiers.isEmpty {
            commands.send(.pinVertical(at: pointer))
        } else if character == "h", modifiers == [.shift] {
            commands.send(.addHorizontalGuideline(y: pointer.y))
        } else if character == "v", modifiers == [.shift] {
            commands.send(.addVerticalGuideline(x: pointer.x))
        }
    }
}
