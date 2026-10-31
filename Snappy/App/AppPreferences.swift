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

    static let measurementDefault = ColorComponents(red: 0.9, green: 0.12, blue: 0.12, opacity: 1)
    static let guidelineDefault = ColorComponents(red: 0.1, green: 0.4, blue: 0.95, opacity: 1)

    var isValid: Bool {
        [red, green, blue, opacity].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

struct AppPreferences: Codable, Equatable {
    var shortcut = ShortcutConfiguration.default
    var measurementColor = ColorComponents.measurementDefault
    var guidelineColor = ColorComponents.guidelineDefault
    var dimensionLabelFontSize = 14.0

    static let `default` = AppPreferences()

    func validated() -> AppPreferences {
        var result = self
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
