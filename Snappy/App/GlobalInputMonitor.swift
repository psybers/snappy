import AppKit
import Combine

@MainActor
final class GlobalInputMonitor: ObservableObject {
    static let shared = GlobalInputMonitor(
        coordinator: .shared,
        permissionManager: .shared
    )

    @Published private(set) var accessibilityPermissionGranted = false
    @Published private(set) var keyboardMonitoringAvailable = false

    private let coordinator: MeasurementCoordinator
    private let permissionManager: AccessibilityPermissionManager
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var gestureOnAnnotation = false
    private var keyboardMonitor: Any?

    init(
        coordinator: MeasurementCoordinator,
        permissionManager: AccessibilityPermissionManager
    ) {
        self.coordinator = coordinator
        self.permissionManager = permissionManager
    }

    func start() {
        if mouseMonitor == nil {
            let mouseMask: NSEvent.EventTypeMask = [
                .mouseMoved,
                .leftMouseDown,
                .leftMouseDragged,
                .leftMouseUp
            ]
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
                let location = NSEvent.mouseLocation
                let point = Point2D(x: location.x, y: location.y)
                Task { @MainActor [weak self] in
                    self?.handleMouseEvent(event.type, at: point)
                }
            }
        }
        if localMouseMonitor == nil {
            // Overlays capture the mouse while measuring, so those events arrive locally.
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                let location = NSEvent.mouseLocation
                let point = Point2D(x: location.x, y: location.y)
                MainActor.assumeIsolated {
                    self?.handleLocalMouse(event.type, at: point)
                }
                return event
            }
        }
        refreshKeyboardPermission()
    }

    private func handleLocalMouse(_ type: NSEvent.EventType, at point: Point2D) {
        if type == .leftMouseDown {
            gestureOnAnnotation = DisplayManager.shared.isHoveringAnnotation
        }
        let suppressed = gestureOnAnnotation
        if type == .leftMouseUp { gestureOnAnnotation = false }
        guard !suppressed else { return }
        handleMouseEvent(type, at: point)
    }

    func stop() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        removeKeyboardMonitor()
    }

    func refreshKeyboardPermission() {
        accessibilityPermissionGranted = permissionManager.refresh()
        guard accessibilityPermissionGranted else {
            removeKeyboardMonitor()
            return
        }
        guard keyboardMonitor == nil else {
            keyboardMonitoringAvailable = true
            return
        }

        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = event.charactersIgnoringModifiers ?? ""
            let modifiers = Self.shortcutModifiers(from: event.modifierFlags)
            Task { @MainActor [weak self] in
                self?.coordinator.keyDown(
                    key: key,
                    keyCode: event.keyCode,
                    modifiers: modifiers
                )
            }
        }
        keyboardMonitoringAvailable = keyboardMonitor != nil
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
        keyboardMonitoringAvailable = false
    }

    private func handleMouseEvent(_ type: NSEvent.EventType, at point: Point2D) {
        switch type {
        case .mouseMoved, .leftMouseDragged:
            coordinator.pointerMoved(to: point)
        case .leftMouseDown:
            coordinator.leftMouseDown(at: point)
        case .leftMouseUp:
            coordinator.leftMouseUp(at: point)
        default:
            break
        }
    }

    private static func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<ShortcutModifier> {
        var result = Set<ShortcutModifier>()
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}
