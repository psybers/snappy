import Foundation

enum ShortcutModifier: String, Codable, CaseIterable, Hashable, Identifiable {
    case command
    case shift
    case option
    case control

    var id: String { rawValue }
}

struct ShortcutConfiguration: Codable, Equatable {
    var key: String
    var modifiers: Set<ShortcutModifier>

    static let `default` = ShortcutConfiguration(key: "F", modifiers: [.command, .shift])

    func normalized() -> ShortcutConfiguration? {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedKey.unicodeScalars.count == 1,
              let scalar = normalizedKey.unicodeScalars.first,
              CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").contains(scalar),
              !modifiers.isEmpty
        else {
            return nil
        }
        return ShortcutConfiguration(key: normalizedKey, modifiers: modifiers)
    }
}

struct ColorComponents: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    static let measurementDefault = ColorComponents(red: 0.99, green: 0.23, blue: 0.31, opacity: 1)
    static let guidelineDefault = ColorComponents(red: 0.0, green: 0.48, blue: 1.0, opacity: 1)

    var isValid: Bool {
        [red, green, blue, opacity].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

enum EdgeToleranceLevel: Int, Codable, CaseIterable, Identifiable {
    case zero, low, medium, high
    var id: Int { rawValue }
    var title: String { ["Zero", "Low", "Medium", "High"][rawValue] }

    func adjusted(by step: Int, wrapping: Bool = false) -> Self {
        let index = rawValue + step
        return Self(rawValue: wrapping ? (index % 4 + 4) % 4 : min(max(index, 0), 3))!
    }
}

struct EdgeToleranceSettings: Codable, Equatable {
    var level: EdgeToleranceLevel = .medium
    var low = 4
    var medium = 8
    var high = 16

    var value: Int {
        switch level {
        case .zero: 0
        case .low: low
        case .medium: medium
        case .high: high
        }
    }

    func validated() -> Self {
        var result = self
        if !(1...100).contains(low) { result.low = 4 }
        if !(result.low...100).contains(medium) { result.medium = max(8, result.low) }
        if !(result.medium...100).contains(high) { result.high = max(16, result.medium) }
        return result
    }
}

struct AppPreferences: Codable, Equatable {
    var shortcut = ShortcutConfiguration.default
    var measurementColor = ColorComponents.measurementDefault
    var guidelineColor = ColorComponents.guidelineDefault
    var dimensionLabelFontSize = 14.0
    // Optional storage preserves decoding of preferences saved before tolerance settings existed.
    var edgeToleranceSettings: EdgeToleranceSettings?
    var edgeTolerance: EdgeToleranceSettings {
        get { edgeToleranceSettings ?? EdgeToleranceSettings() }
        set { edgeToleranceSettings = newValue }
    }

    static let `default` = AppPreferences()

    func validated() -> AppPreferences {
        var result = self
        if let edgeToleranceSettings {
            result.edgeToleranceSettings = edgeToleranceSettings.validated()
        }
        result.shortcut = shortcut.normalized() ?? .default
        if !measurementColor.isValid {
            result.measurementColor = .measurementDefault
        }
        if !guidelineColor.isValid {
            result.guidelineColor = .guidelineDefault
        }
        if !dimensionLabelFontSize.isFinite || !(8...48).contains(dimensionLabelFontSize) {
            result.dimensionLabelFontSize = AppPreferences.default.dimensionLabelFontSize
        }
        return result
    }
}
