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

    func resetToDefaults() {
        update { $0 = .default }
    }

    func setEdgeToleranceLevel(_ level: EdgeToleranceLevel) {
        update { $0.edgeTolerance.level = level }
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
