import Combine
import Foundation

final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    @Published private(set) var preferences: AppPreferences
    @Published private(set) var validationMessage: String?
    @Published private(set) var persistenceError: String?

    private let defaults: UserDefaults
    private let storageKey = "snappy.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey) {
            do {
                preferences = try JSONDecoder().decode(AppPreferences.self, from: data).validated()
            } catch {
                preferences = .default
                persistenceError = "Saved preferences could not be read: \(error.localizedDescription)"
                return
            }
        } else {
            preferences = .default
        }
    }

    func setShortcutKey(_ key: String) {
        var shortcut = preferences.shortcut
        shortcut.key = key
        guard let normalized = shortcut.normalized() else {
            validationMessage = "Use one letter or number and keep at least one modifier enabled."
            return
        }
        update { $0.shortcut = normalized }
    }

    func setModifier(_ modifier: ShortcutModifier, enabled: Bool) {
        var shortcut = preferences.shortcut
        if enabled {
            shortcut.modifiers.insert(modifier)
        } else {
            shortcut.modifiers.remove(modifier)
        }
        guard let normalized = shortcut.normalized() else {
            validationMessage = "At least one shortcut modifier must remain enabled."
            return
        }
        update { $0.shortcut = normalized }
    }

    func setMeasurementColor(_ color: ColorComponents) {
        guard color.isValid else {
            validationMessage = "Choose a valid measurement color."
            return
        }
        update { $0.measurementColor = color }
    }

    func setGuidelineColor(_ color: ColorComponents) {
        guard color.isValid else {
            validationMessage = "Choose a valid guideline color."
            return
        }
        update { $0.guidelineColor = color }
    }

    func setDimensionLabelFontSize(_ size: Double) {
        guard size.isFinite, (8...48).contains(size) else {
            validationMessage = "Label font size must be between 8 and 48 points."
            return
        }
        update { $0.dimensionLabelFontSize = size }
    }

    func setLineThickness(_ thickness: Double, for keyPath: WritableKeyPath<AppPreferences, Double>) {
        guard thickness.isFinite, (1...10).contains(thickness) else {
            validationMessage = "Line thickness must be between 1 and 10 points."
            return
        }
        update { $0[keyPath: keyPath] = thickness }
    }

    func resetToDefaults() {
        update { $0 = .default }
    }

    func setEdgeToleranceLevel(_ level: EdgeToleranceLevel) {
        update {
            $0.edgeTolerance.level = level
            $0.edgeTolerance.temporaryValue = nil
        }
    }

    /// Steps the tolerance selection. `step == 0` cycles levels with
    /// wraparound (T); ±1 moves without wrapping (-/=). While a temporary
    /// nudge is active, - and = instead jump to the nearest preset value
    /// below/above the effective value, since the level index no longer
    /// describes where the value sits.
    func stepEdgeTolerance(by step: Int, wrapping: Bool) {
        let settings = preferences.edgeTolerance
        if step != 0 && !wrapping, settings.temporaryValue != nil {
            var presets: [(level: EdgeToleranceLevel, value: Int)] = []
            for level in EdgeToleranceLevel.allCases {
                let value = settings.presetValue(for: level)
                if !presets.contains(where: { $0.value == value }) {
                    presets.append((level, value))
                }
            }
            presets.sort { $0.value < $1.value }
            let target = step < 0
                ? presets.last(where: { $0.value < settings.value })
                : presets.first(where: { $0.value > settings.value })
            guard let target else { return }
            setEdgeToleranceLevel(target.level)
            return
        }
        let current = settings.level
        let next = current.adjusted(by: step == 0 ? 1 : step, wrapping: wrapping)
        guard next != current else { return }
        setEdgeToleranceLevel(next)
    }

    /// Nudges the effective tolerance by `delta` for this session only. The
    /// change is published (toast, rescan) but deliberately not written to
    /// defaults, and landing on a preset value reselects that preset.
    func adjustTemporaryEdgeTolerance(by delta: Int) {
        var settings = preferences.edgeTolerance
        let current = settings.value
        let updated = min(max(current + delta, 0), 100)
        guard updated != current else { return }
        let presets: [(EdgeToleranceLevel, Int)] = [
            (.zero, 0), (.low, settings.low), (.medium, settings.medium), (.high, settings.high),
        ]
        if let match = presets.first(where: { $0.0 == settings.level && $0.1 == updated })?.0
            ?? presets.first(where: { $0.1 == updated })?.0
        {
            settings.level = match
            settings.temporaryValue = nil
        } else {
            settings.temporaryValue = updated
        }
        preferences.edgeTolerance = settings
        validationMessage = nil
    }

    func setEdgeToleranceValue(_ value: Int, for level: EdgeToleranceLevel) {
        var settings = preferences.edgeTolerance
        switch level {
        case .zero: return
        case .low: settings.low = value
        case .medium: settings.medium = value
        case .high: settings.high = value
        }
        guard (1...100).contains(value), settings.low <= settings.medium, settings.medium <= settings.high else {
            validationMessage = "Use values from 1 to 100, with Low ≤ Medium ≤ High."
            return
        }
        settings.temporaryValue = nil
        update { $0.edgeTolerance = settings }
    }

    private func update(_ change: (inout AppPreferences) -> Void) {
        var updated = preferences
        change(&updated)
        preferences = updated.validated()
        validationMessage = nil
        do {
            let data = try JSONEncoder().encode(preferences)
            defaults.set(data, forKey: storageKey)
            persistenceError = nil
        } catch {
            persistenceError = "Preferences could not be saved: \(error.localizedDescription)"
        }
    }
}
