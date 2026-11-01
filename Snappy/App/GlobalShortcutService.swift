import AppKit
import Carbon
import Combine
import Foundation
import ScreenCaptureKit

private let snappyHotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == GlobalShortcutService.signature
    else {
        return OSStatus(eventNotHandledErr)
    }
    let service = Unmanaged<GlobalShortcutService>.fromOpaque(userData).takeUnretainedValue()
    let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    Task { @MainActor in
        if released {
            service.handleHotKeyRelease(identifier: hotKeyID.id)
        } else {
            service.handleHotKey(identifier: hotKeyID.id)
        }
    }
    return noErr
}

@MainActor
final class GlobalShortcutService: ObservableObject {
    static let shared = GlobalShortcutService()
    nonisolated static let signature = OSType(0x534E4150)

    @Published private(set) var registrationError: String?

    private let coordinator: MeasurementCoordinator
    private let inputMonitor: GlobalInputMonitor
    private let displayManager: DisplayManager
    private let preferencesStore: PreferencesStore
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var retiredHotKeys: [EventHotKeyRef] = []
    private var activeHotKeyID: UInt32?
    private var nextHotKeyID = UInt32(1)
    private var preferencesSubscription: AnyCancellable?
    private var isStarted = false
    private var escapeHotKey: EventHotKeyRef?
    private var annotationHotKeys: [UInt32: EventHotKeyRef] = [:]
    private var arrowRepeatTimer: Timer?
    private var repeatingArrowID: UInt32?
    // Carbon hotkeys need no Accessibility/Input Monitoring permission, unlike global key monitors.
    private static let annotationKeys: [UInt32: (key: String, code: Int, shift: Bool)] = [
        0xA01: ("h", kVK_ANSI_H, false),
        0xA02: ("v", kVK_ANSI_V, false),
        0xA03: ("h", kVK_ANSI_H, true),
        0xA04: ("v", kVK_ANSI_V, true),
        0xA05: ("", kVK_LeftArrow, false),
        0xA06: ("", kVK_RightArrow, false),
        0xA07: ("", kVK_DownArrow, false),
        0xA08: ("", kVK_UpArrow, false),
        0xA09: ("", kVK_LeftArrow, true),
        0xA0A: ("", kVK_RightArrow, true),
        0xA0B: ("", kVK_DownArrow, true),
        0xA0C: ("", kVK_UpArrow, true),
    ]
    private var modeSubscription: AnyCancellable?
    private static let escapeHotKeyID: UInt32 = 0xE5C
    /// Returns true when measuring may start; otherwise it triggers the system permission prompt.
    var screenAccessGate: () async -> Bool = {
        await ScreenAccessProbe.verify(promptIfDenied: true)
    }

    convenience init() {
        self.init(
            coordinator: .shared,
            inputMonitor: .shared,
            displayManager: .shared,
            preferencesStore: .shared
        )
    }

    init(
        coordinator: MeasurementCoordinator,
        inputMonitor: GlobalInputMonitor,
        displayManager: DisplayManager,
        preferencesStore: PreferencesStore
    ) {
        self.coordinator = coordinator
        self.inputMonitor = inputMonitor
        self.displayManager = displayManager
        self.preferencesStore = preferencesStore
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installCarbonHandler()
        modeSubscription = coordinator.$mode
            .map(\.isActive)
            .removeDuplicates()
            .sink { [weak self] active in
                self?.setEscapeHotKey(enabled: active)
            }
        preferencesSubscription = preferencesStore.$preferences
            .map(\.shortcut)
            .removeDuplicates()
            .sink { [weak self] shortcut in
                self?.register(shortcut)
            }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        preferencesSubscription?.cancel()
        preferencesSubscription = nil
        modeSubscription?.cancel()
        modeSubscription = nil
        setEscapeHotKey(enabled: false)
        unregisterHotKey()
        guard hotKey == nil, retiredHotKeys.isEmpty else { return }
        if let eventHandler {
            let status = RemoveEventHandler(eventHandler)
            guard status == noErr else {
                registrationError = "Global shortcut handler could not be removed (OSStatus \(status))."
                return
            }
            self.eventHandler = nil
        }
    }

    func handleHotKey(identifier: UInt32? = nil) {
        if identifier == Self.escapeHotKeyID {
            coordinator.stop()
            return
        }
        if let identifier, let entry = Self.annotationKeys[identifier] {
            if (123...126).contains(entry.code) {
                guard coordinator.mode.isActive, repeatingArrowID != identifier else { return }
                stopArrowRepeat()
                repeatingArrowID = identifier
                let timer = Timer(fire: Date().addingTimeInterval(NSEvent.keyRepeatDelay),
                                  interval: NSEvent.keyRepeatInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.repeatArrow()
                    }
                }
                arrowRepeatTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            coordinator.keyDown(
                key: entry.key,
                keyCode: UInt16(entry.code),
                modifiers: entry.shift ? [.shift] : []
            )
            return
        }
        if let identifier, identifier != activeHotKeyID { return }
        // Without permission, do nothing but let the system dialog be answered.
        Task { @MainActor [weak self] in
            guard let self, await screenAccessGate() else { return }
            beginMeasuring()
        }
    }

    func handleHotKeyRelease(identifier: UInt32) {
        if repeatingArrowID == identifier { stopArrowRepeat() }
    }

    private func stopArrowRepeat() {
        arrowRepeatTimer?.invalidate()
        arrowRepeatTimer = nil
        repeatingArrowID = nil
    }

    func repeatArrow() {
        guard coordinator.mode.isActive,
              let identifier = repeatingArrowID,
              let entry = Self.annotationKeys[identifier] else {
            stopArrowRepeat()
            return
        }
        coordinator.keyDown(key: entry.key, keyCode: UInt16(entry.code),
                            modifiers: NSEvent.modifierFlags.contains(.shift) ? [.shift] : [])
    }

    private func beginMeasuring() {
        inputMonitor.start()
        coordinator.startFreshSession(
            displays: displayManager.connectedDisplays,
            pointer: currentPointer(),
            shiftHeldAtActivation: NSEvent.modifierFlags.contains(.shift)
        )
        displayManager.replaceAnnotationGroups(coordinator.activeSession?.displays ?? [])
    }

    nonisolated static func virtualKeyCode(for key: String) -> UInt32? {
        let key = key.uppercased()
        let keyCodes: [String: UInt32] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
            "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
            "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "EQUAL": 24, "9": 25, "7": 26, "MINUS": 27, "8": 28,
            "0": 29, "RIGHTBRACKET": 30, "O": 31, "U": 32, "LEFTBRACKET": 33,
            "I": 34, "P": 35, "L": 37, "J": 38, "APOSTROPHE": 39, "K": 40,
            "SEMICOLON": 41, "BACKSLASH": 42, "COMMA": 43, "SLASH": 44,
            "N": 45, "M": 46, "PERIOD": 47, "GRAVE": 50
        ]
        guard key.count == 1 else { return nil }
        return keyCodes[key]
    }

    private func installCarbonHandler() {
        guard eventHandler == nil else { return }
        var eventTypes = [EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        ), EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                         eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            snappyHotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            registrationError = "Global shortcut handler could not be installed (OSStatus \(status))."
        }
    }

    private func register(_ configuration: ShortcutConfiguration) {
        guard let normalized = configuration.normalized(),
              let keyCode = Self.virtualKeyCode(for: normalized.key)
        else {
            registrationError = "The selected shortcut key is not supported."
            return
        }
        guard eventHandler != nil else {
            registrationError = "Global shortcut handler is unavailable."
            return
        }

        let modifiers = carbonModifiers(for: normalized.modifiers)
        let candidateID = nextHotKeyID
        nextHotKeyID &+= 1
        let identifier = EventHotKeyID(signature: Self.signature, id: candidateID)
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &candidate
        )
        guard status == noErr, let candidate else {
            registrationError = "Global shortcut registration failed (OSStatus \(status)). It may already be in use."
            return
        }

        let previousHotKey = hotKey
        hotKey = candidate
        activeHotKeyID = candidateID
        if let previousHotKey {
            let unregisterStatus = UnregisterEventHotKey(previousHotKey)
            if unregisterStatus != noErr {
                retiredHotKeys.append(previousHotKey)
            }
        }
        releaseRetiredHotKeys()
        registrationError = retiredHotKeys.isEmpty
            ? nil
            : "A previous global shortcut could not be released."
    }

    private func setEscapeHotKey(enabled: Bool) {
        setAnnotationHotKeys(enabled: enabled)
        if enabled {
            guard escapeHotKey == nil, eventHandler != nil else { return }
            var candidate: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(kVK_Escape),
                0,
                EventHotKeyID(signature: Self.signature, id: Self.escapeHotKeyID),
                GetApplicationEventTarget(),
                0,
                &candidate
            )
            if status == noErr { escapeHotKey = candidate }
        } else if let escapeHotKey {
            UnregisterEventHotKey(escapeHotKey)
            self.escapeHotKey = nil
        }
    }

    private func setAnnotationHotKeys(enabled: Bool) {
        if !enabled { stopArrowRepeat() }
        if enabled {
            guard eventHandler != nil else { return }
            for (id, entry) in Self.annotationKeys where annotationHotKeys[id] == nil {
                var candidate: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    UInt32(entry.code),
                    entry.shift ? UInt32(shiftKey) : 0,
                    EventHotKeyID(signature: Self.signature, id: id),
                    GetApplicationEventTarget(),
                    0,
                    &candidate
                )
                if status == noErr, let candidate { annotationHotKeys[id] = candidate }
            }
        } else {
            annotationHotKeys.values.forEach { UnregisterEventHotKey($0) }
            annotationHotKeys.removeAll()
        }
    }

    private func unregisterHotKey() {
        if let hotKey {
            let status = UnregisterEventHotKey(hotKey)
            self.hotKey = nil
            activeHotKeyID = nil
            if status != noErr {
                retiredHotKeys.append(hotKey)
            }
        }
        releaseRetiredHotKeys()
        if !retiredHotKeys.isEmpty {
            registrationError = "A global shortcut could not be released."
        }
    }

    private func releaseRetiredHotKeys() {
        var unreleasedHotKeys: [EventHotKeyRef] = []
        for retiredHotKey in retiredHotKeys {
            if UnregisterEventHotKey(retiredHotKey) != noErr {
                unreleasedHotKeys.append(retiredHotKey)
            }
        }
        retiredHotKeys = unreleasedHotKeys
    }

    private func carbonModifiers(for modifiers: Set<ShortcutModifier>) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private func currentPointer() -> Point2D {
        let pointer = NSEvent.mouseLocation
        return Point2D(x: pointer.x, y: pointer.y)
    }
}

/// CGPreflightScreenCaptureAccess can stay false after the user grants access until relaunch,
/// so fall back to asking ScreenCaptureKit directly.
enum ScreenAccessProbe {
    @MainActor private(set) static var verified = false
    @MainActor private static var requestedThisRun = false
    @MainActor private static var checking = false

    @MainActor
    static func verify(promptIfDenied: Bool) async -> Bool {
        guard !checking else { return false }
        checking = true
        defer { checking = false }
        if CGPreflightScreenCaptureAccess() {
            verified = true
            return true
        }
        // Public APIs cannot tell an absent privacy entry from a disabled one.
        // Give macOS the first request of each run, without following its dialog
        // with our own. A persisted flag would become stale after a TCC reset.
        if promptIfDenied && !requestedThisRun {
            requestedThisRun = true
            verified = CGRequestScreenCaptureAccess()
            return verified
        }
        if (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil {
            verified = true
            return true
        }
        verified = false
        guard promptIfDenied else { return false }
        showEnableAlert()
        return false
    }

    private static var alertShowing = false

    @MainActor
    private static func showEnableAlert() {
        guard !alertShowing else { return }
        alertShowing = true
        defer { alertShowing = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Snappy needs Screen Recording access"
        alert.informativeText =
            "Enable Snappy in System Settings › Privacy & Security › Screen Recording, then press the shortcut again. You may need to relaunch Snappy."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
