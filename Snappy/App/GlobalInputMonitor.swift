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
    private var localModifierMonitor: Any?
    private var gestureOnAnnotation = false
    private var keyboardMonitor: Any?
    private var modeSubscription: AnyCancellable?
    private var modifierTimer: Timer?

    /// AppKit uses bottom-left points; cursor warping uses top-left global points.
    static func moveCursor(from pointer: Point2D, dxPixels: Double, dyPixels: Double) -> Point2D? {
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: pointer.x, y: pointer.y))
        }), let primary = NSScreen.screens.first else { return nil }
        let scale = screen.backingScaleFactor
        var target = NSPoint(x: pointer.x + dxPixels / scale, y: pointer.y + dyPixels / scale)
        // Permit crossing onto adjacent displays, but keep the pointer out of desktop gaps.
        if !NSScreen.screens.contains(where: { $0.frame.contains(target) }) {
            target.x = min(max(target.x, screen.frame.minX), screen.frame.maxX - 1 / scale)
            target.y = min(max(target.y, screen.frame.minY), screen.frame.maxY - 1 / scale)
        }
        guard CGWarpMouseCursorPosition(CGPoint(x: target.x, y: primary.frame.maxY - target.y)) == .success
        else { return nil }
        return Point2D(x: target.x, y: target.y)
    }

    init(
        coordinator: MeasurementCoordinator,
        permissionManager: AccessibilityPermissionManager
    ) {
        self.coordinator = coordinator
        self.permissionManager = permissionManager
    }

    func start() {
        if modeSubscription == nil {
            modeSubscription = coordinator.$mode
                .map(\.isActive)
                .removeDuplicates()
                .sink { [weak self] active in
                    self?.setModifierTracking(active: active)
                }
        }
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
                let modifiers = Self.shortcutModifiers(from: event.modifierFlags)
                let shiftHeld = modifiers.contains(.shift)
                Task { @MainActor [weak self] in
                    self?.handleMouseEvent(event.type, at: point, shiftHeld: shiftHeld)
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
                    self?.handleLocalMouse(event.type, at: point, shiftHeld: event.modifierFlags.contains(.shift))
                }
                return event
            }
        }
        if localModifierMonitor == nil {
            localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.coordinator.updateShiftState(event.modifierFlags.contains(.shift))
                }
                return event
            }
        }
        refreshKeyboardPermission()
    }

    private func handleLocalMouse(_ type: NSEvent.EventType, at point: Point2D, shiftHeld: Bool) {
        if type == .leftMouseDown {
            gestureOnAnnotation = DisplayManager.shared.isHoveringAnnotation
        }
        let suppressed = gestureOnAnnotation
        if type == .leftMouseUp { gestureOnAnnotation = false }
        guard !suppressed else { return }
        handleMouseEvent(type, at: point, shiftHeld: shiftHeld)
    }

    private func setModifierTracking(active: Bool) {
        modifierTimer?.invalidate()
        modifierTimer = nil
        guard active else { return }
        // Reading aggregate modifier state needs no global keyboard monitoring permission.
        // Keep this fallback scoped to measurement mode; never capture key events here.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coordinator.updateShiftState(NSEvent.modifierFlags.contains(.shift))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierTimer = timer
    }

    func stop() {
        modeSubscription?.cancel()
        modeSubscription = nil
        setModifierTracking(active: false)
        if let localModifierMonitor {
            NSEvent.removeMonitor(localModifierMonitor)
            self.localModifierMonitor = nil
        }
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

        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let modifiers = Self.shortcutModifiers(from: event.modifierFlags)
            Task { @MainActor [weak self] in
                // Track Shift key state for crosshair mode
                if event.type == .flagsChanged {
                    let shiftHeld = modifiers.contains(.shift)
                    // Update coordinator state so it's in sync
                    self?.coordinator.updateShiftState(shiftHeld)
                } else if event.type == .keyDown {
                    let key = event.charactersIgnoringModifiers ?? ""
                    self?.coordinator.keyDown(
                        key: key,
                        keyCode: event.keyCode,
                        modifiers: modifiers
                    )
                }
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

    private func handleMouseEvent(_ type: NSEvent.EventType, at point: Point2D, shiftHeld: Bool) {
        switch type {
        case .mouseMoved, .leftMouseDragged:
            coordinator.pointerMoved(to: point, shiftHeld: shiftHeld)
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
