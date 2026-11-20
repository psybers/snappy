import AppKit
import SwiftUI

private enum PreferencesTab: String, CaseIterable, Identifiable {
    case general, tolerance, appearance, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .tolerance: "Tolerance"
        case .appearance: "Appearance"
        case .shortcuts: "Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .tolerance: "slider.horizontal.3"
        case .appearance: "paintpalette"
        case .shortcuts: "keyboard"
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var store: PreferencesStore
    @ObservedObject private var inputMonitor = GlobalInputMonitor.shared
    @ObservedObject private var shortcutService = GlobalShortcutService.shared
    @ObservedObject private var accessibilityPermissions = AccessibilityPermissionManager.shared
    @ObservedObject private var screenRecordingPermissions = ScreenRecordingPermissionManager.shared
    @State private var settingsOpenError: String?
    @State private var selectedTab: PreferencesTab = .general

    init(store: PreferencesStore = .shared) {
        self.store = store
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("Preferences", selection: $selectedTab) {
                ForEach(PreferencesTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            selectedTabContent
        }
        .fixedSize(horizontal: false, vertical: true)
        .scenePadding()
        .background(WindowResizeAnimator(trigger: selectedTab))
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

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .general:
            generalTab
        case .tolerance:
            toleranceTab
        case .appearance:
            appearanceTab
        case .shortcuts:
            shortcutsTab
        }
    }

    private var generalTab: some View {
        Form {
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
                        openPrivacyPane("Accessibility", query: "Privacy_Accessibility")
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
                        openPrivacyPane("Screen Recording", query: "Privacy_ScreenCapture")
                    }
                }
            }

            statusMessages
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var toleranceTab: some View {
        Form {
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

            statusMessages

            restoreDefaultsButton { store.resetEdgeToleranceToDefaults() }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var appearanceTab: some View {
        Form {
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

            Section("Line thickness") {
                HStack(alignment: .center, spacing: 8) {
                    VStack(spacing: 8) {
                        thicknessRow("Measurement mode", keyPath: \.measurementLineThickness)
                        pinnedThicknessRow()
                    }
                    pinnedLockButton()
                }
                thicknessRow("Guidelines", keyPath: \.guidelineLineThickness)
                thicknessRow("Rectangles", keyPath: \.rectangleLineThickness)
                Text("Hovering an annotation draws its lines slightly thicker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            statusMessages

            restoreDefaultsButton { store.resetAppearanceToDefaults() }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var shortcutsTab: some View {
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

            statusMessages

            restoreDefaultsButton { store.resetShortcutToDefaults() }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Validation and persistence errors apply to every tab's controls, so
    /// they are shown on each tab rather than only where they originated.
    @ViewBuilder
    private var statusMessages: some View {
        if let validationMessage = store.validationMessage {
            Text(validationMessage)
                .foregroundStyle(.orange)
        }

        if let persistenceError = store.persistenceError {
            Text(persistenceError)
                .foregroundStyle(.red)
        }
    }

    private func restoreDefaultsButton(_ action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Restore Defaults", action: action)
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

    /// Shared width for the thickness row labels, sized to fit
    /// "Measurement mode"; trailing alignment keeps both sliders flush.
    private static let thicknessLabelWidth: CGFloat = 120

    private func thicknessLabel(_ title: String) -> some View {
        Text(title)
            .frame(width: Self.thicknessLabelWidth, alignment: .trailing)
    }

    private func thicknessRow(_ title: String, keyPath: WritableKeyPath<AppPreferences, Double>) -> some View {
        HStack {
            thicknessLabel(title)
            Slider(value: thicknessBinding(for: keyPath), in: 1...10, step: 0.5)
                .accessibilityLabel("\(title) line thickness")
            Text(thicknessText(store.preferences[keyPath: keyPath]))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func pinnedThicknessRow() -> some View {
        HStack {
            thicknessLabel("Pinned lines")
            Slider(value: pinnedThicknessBinding, in: 1...10, step: 0.5)
                .disabled(store.preferences.pinnedLineThicknessLocked)
                .accessibilityLabel("Pinned lines line thickness")
            Text(thicknessText(store.preferences.pinnedLineThickness))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func pinnedLockButton() -> some View {
        let locked = store.preferences.pinnedLineThicknessLocked
        return Button {
            store.setPinnedLineThicknessLocked(!locked)
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(locked
            ? "Pinned lines match the measurement mode thickness. Click to adjust independently."
            : "Pinned lines have an independent thickness. Click to match measurement mode.")
    }

    private var pinnedThicknessBinding: Binding<Double> {
        Binding(
            get: { store.preferences.pinnedLineThickness },
            set: { store.setLineThickness($0, for: \.pinnedLineThickness) }
        )
    }

    private func thicknessBinding(for keyPath: WritableKeyPath<AppPreferences, Double>) -> Binding<Double> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { store.setLineThickness($0, for: keyPath) }
        )
    }

    private func thicknessText(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) pt" : String(format: "%.1f pt", value)
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

    private func openPrivacyPane(_ name: String, query: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(query)"
        ) else {
            settingsOpenError = "The \(name) settings URL is unavailable."
            return
        }
        guard NSWorkspace.shared.open(url) else {
            settingsOpenError = "System Settings could not be opened."
            return
        }
        settingsOpenError = nil
    }
}

private struct WindowResizeAnimator: NSViewRepresentable {
    let trigger: PreferencesTab

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        let previousTrigger = coordinator.trigger
        coordinator.trigger = trigger
        guard let previousTrigger, previousTrigger != trigger else { return }

        DispatchQueue.main.async { [weak nsView] in
            guard let nsView,
                  coordinator.trigger == trigger,
                  let window = nsView.window,
                  let contentView = window.contentView else { return }

            contentView.layoutSubtreeIfNeeded()
            let contentSize = contentView.fittingSize
            guard contentSize.width > 0, contentSize.height > 0 else { return }

            let frameSize = window.frameRect(
                forContentRect: NSRect(origin: .zero, size: contentSize)
            ).size
            guard abs(window.frame.height - frameSize.height) > 1 else { return }

            var frame = window.frame
            frame.origin.y += frame.height - frameSize.height
            frame.size = frameSize
            window.setFrame(frame, display: true, animate: true)
        }
    }

    final class Coordinator {
        var trigger: PreferencesTab?
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
