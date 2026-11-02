import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var store: PreferencesStore
    @ObservedObject private var inputMonitor = GlobalInputMonitor.shared
    @ObservedObject private var shortcutService = GlobalShortcutService.shared
    @ObservedObject private var accessibilityPermissions = AccessibilityPermissionManager.shared
    @ObservedObject private var screenRecordingPermissions = ScreenRecordingPermissionManager.shared
    @State private var settingsOpenError: String?

    init(store: PreferencesStore = .shared) {
        self.store = store
    }

    var body: some View {
        ScrollView {
        Form {
            Section("Measurement shortcut") {
                HStack {
                    TextField("Key", text: shortcutKeyBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .accessibilityLabel("Shortcut key")
                    Text("The shortcut applies globally while Snappy is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    ForEach(ShortcutModifier.allCases) { modifier in
                        Toggle(modifier.rawValue.capitalized, isOn: modifierBinding(modifier))
                    }
                }
                if let registrationError = shortcutService.registrationError {
                    Text(registrationError)
                        .foregroundStyle(.red)
                }
            }

            Section("Edge tolerance") {
                Picker("Level", selection: Binding(
                    get: { store.preferences.edgeTolerance.level },
                    set: { store.setEdgeToleranceLevel($0) }
                )) {
                    ForEach(EdgeToleranceLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                Text("Zero is fixed at 0. Higher values ignore larger color differences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach([EdgeToleranceLevel.low, .medium, .high]) { level in
                    HStack {
                        Text(level.title)
                            .frame(width: 60, alignment: .leading)
                        Slider(value: toleranceBinding(for: level), in: 1...100, step: 1)
                            .accessibilityLabel("\(level.title) edge tolerance")
                        Text("\(Int(toleranceBinding(for: level).wrappedValue))")
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                Text("Use T to cycle, − to decrease, and = to increase while measuring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                ColorPicker(
                    "Measurement indicators",
                    selection: colorBinding(for: \.measurementColor)
                )
                ColorPicker(
                    "Guidelines",
                    selection: colorBinding(for: \.guidelineColor)
                )
                HStack {
                    Text("Dimension label size")
                    Slider(value: fontSizeBinding, in: 8...48, step: 1)
                    Text("\(Int(store.preferences.dimensionLabelFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }

            Section("System Permissions") {
                if accessibilityPermissions.isTrusted {
                    Label("Accessibility permission is enabled.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Text("Enable Snappy under Privacy & Security > Accessibility in System Settings. This permission allows Snappy to inspect the UI element under the pointer and receive H, V, and Escape while another app is active. The global shortcut and pointer tracking work separately. Some apps may not expose useful element boundaries.")
                        .font(.callout)

                    Button("Request Accessibility Permission") {
                        accessibilityPermissions.requestPrompt()
                        inputMonitor.refreshKeyboardPermission()
                    }

                    Button("Open Accessibility Settings") {
                        openAccessibilitySettings()
                    }
                }
                if accessibilityPermissions.isTrusted && !inputMonitor.keyboardMonitoringAvailable {
                    Text("Accessibility is trusted, but global keyboard monitoring could not be started. Use the menu to exit measurement mode.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let settingsOpenError {
                    Text(settingsOpenError)
                        .foregroundStyle(.red)
                }
                if screenRecordingPermissions.isAuthorized {
                    Label("Screen Recording permission is enabled.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Text("Screen Recording lets Snappy capture a small region around the pointer when the current app does not expose a usable Accessibility boundary. Captures are requested only as needed and are not saved.")
                        .font(.callout)

                    Button("Request Screen Recording Permission") {
                        screenRecordingPermissions.requestPrompt()
                    }

                    Button("Open Screen Recording Settings") {
                        openScreenRecordingSettings()
                    }
                }
                if let settingsOpenError {
                    Text(settingsOpenError)
                        .foregroundStyle(.red)
                }
            }

            if let validationMessage = store.validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.orange)
            }

            if let persistenceError = store.persistenceError {
                Text(persistenceError)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    store.resetToDefaults()
                }
            }
        }
        .padding(20)
        }
        .frame(width: 560, height: min(800, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
        .navigationTitle("Snappy Preferences")
        .background(PreferencesWindowFocus())
        .onAppear {
            accessibilityPermissions.refresh()
            inputMonitor.refreshKeyboardPermission()
            screenRecordingPermissions.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityPermissions.refresh()
            inputMonitor.refreshKeyboardPermission()
            screenRecordingPermissions.refresh()
        }
    }

    private var shortcutKeyBinding: Binding<String> {
        Binding(
            get: { store.preferences.shortcut.key },
            set: { store.setShortcutKey($0) }
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { store.preferences.dimensionLabelFontSize },
            set: { store.setDimensionLabelFontSize($0) }
        )
    }

    private func toleranceBinding(for level: EdgeToleranceLevel) -> Binding<Double> {
        Binding(
            get: {
                var settings = store.preferences.edgeTolerance
                settings.level = level
                return Double(settings.value)
            },
            set: { store.setEdgeToleranceValue(Int($0.rounded()), for: level) }
        )
    }

    private func modifierBinding(_ modifier: ShortcutModifier) -> Binding<Bool> {
        Binding(
            get: { store.preferences.shortcut.modifiers.contains(modifier) },
            set: { store.setModifier(modifier, enabled: $0) }
        )
    }

    private func colorBinding(
        for keyPath: WritableKeyPath<AppPreferences, ColorComponents>
    ) -> Binding<Color> {
        Binding(
            get: { store.preferences[keyPath: keyPath].swiftUIColor },
            set: { color in
                guard let components = ColorComponents(color: color) else { return }
                if keyPath == \.measurementColor {
                    store.setMeasurementColor(components)
                } else {
                    store.setGuidelineColor(components)
                }
            }
        )
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            settingsOpenError = "The Accessibility settings URL is unavailable."
            return
        }
        guard NSWorkspace.shared.open(url) else {
            settingsOpenError = "System Settings could not be opened."
            return
        }
        settingsOpenError = nil
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            settingsOpenError = "The Screen Recording settings URL is unavailable."
            return
        }
        guard NSWorkspace.shared.open(url) else {
            settingsOpenError = "System Settings could not be opened."
            return
        }
        settingsOpenError = nil
    }
}

@MainActor
final class PreferencesWindowPresenter {
    static let shared = PreferencesWindowPresenter()
    weak var window: NSWindow?

    func focus() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Register the actual settings window so the menu can focus it on every click,
/// even when SwiftUI reuses the existing view without another appearance callback.
private struct PreferencesWindowFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusView { FocusView() }
    func updateNSView(_ nsView: FocusView, context: Context) {}

    final class FocusView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            PreferencesWindowPresenter.shared.window = window
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                guard PreferencesWindowPresenter.shared.window === window else { return }
                PreferencesWindowPresenter.shared.focus()
            }
        }
    }
}

private extension ColorComponents {
    var swiftUIColor: Color {
        Color(
            .sRGB,
            red: red,
            green: green,
            blue: blue,
            opacity: opacity
        )
    }

    init?(color: Color) {
        guard let resolved = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            opacity: Double(resolved.alphaComponent)
        )
    }
}
