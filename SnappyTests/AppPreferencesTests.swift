import XCTest

/// Tests for `AppPreferences.swift`: `AppPreferences`,
/// `EdgeToleranceSettings`, `EdgeToleranceLevel`, and
/// `ShortcutConfiguration` value types and validation.
final class AppPreferencesTests: XCTestCase {
    func testToleranceDefaultsCyclingAndLimits() {
        let settings = AppPreferences.default.edgeTolerance
        XCTAssertEqual(settings.level, .medium)
        XCTAssertEqual(settings.value, PixelExtentDetector().edgeThreshold)
        XCTAssertEqual(settings.low, 4)
        XCTAssertEqual(settings.high, 16)
        XCTAssertEqual(EdgeToleranceLevel.high.adjusted(by: 1, wrapping: true), .zero)
        XCTAssertEqual(EdgeToleranceLevel.zero.adjusted(by: -1), .zero)
        XCTAssertEqual(EdgeToleranceLevel.high.adjusted(by: 1), .high)
        XCTAssertEqual(EdgeToleranceLevel.medium.adjusted(by: -1), .low)
        var zero = settings
        zero.level = .zero
        XCTAssertEqual(zero.value, 0)
    }

    func testOldPreferencesKeepTheirValuesAndGetMediumTolerance() throws {
        var preferences = AppPreferences.default
        preferences.dimensionLabelFontSize = 23
        let data = try JSONEncoder().encode(preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["edgeToleranceSettings"])
        let restored = try JSONDecoder().decode(AppPreferences.self, from: data).validated()
        XCTAssertEqual(restored.dimensionLabelFontSize, 23)
        XCTAssertEqual(restored.edgeTolerance.level, .medium)
        XCTAssertEqual(restored.edgeTolerance.value, 8)
    }

    func testTemporaryToleranceIsNotEncoded() throws {
        var settings = EdgeToleranceSettings()
        settings.temporaryValue = 11
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EdgeToleranceSettings.self, from: data)
        XCTAssertNil(decoded.temporaryValue)
        XCTAssertEqual(decoded.value, 8)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("temporaryValue"))
    }

    func testPreferencesDefaultsAndValidation() {
        XCTAssertEqual(AppPreferences.default.shortcut, .default)
        XCTAssertEqual(AppPreferences.default.measurementColor, .measurementDefault)
        XCTAssertEqual(AppPreferences.default.guidelineColor, .guidelineDefault)
        XCTAssertEqual(AppPreferences.default.dimensionLabelFontSize, 14)
        XCTAssertEqual(AppPreferences.default.measurementLineThickness, 1)
        XCTAssertEqual(AppPreferences.default.pinnedLineThickness, 1)
        XCTAssertEqual(AppPreferences.default.guidelineLineThickness, 1)
        XCTAssertEqual(AppPreferences.default.rectangleLineThickness, 1)

        var invalid = AppPreferences.default
        invalid.shortcut = ShortcutConfiguration(key: "escape", modifiers: [.command])
        invalid.measurementColor.red = .infinity
        invalid.dimensionLabelFontSize = 100
        invalid.rectangleLineThickness = 0
        invalid.guidelineLineThickness = .infinity

        XCTAssertEqual(invalid.validated(), .default)
    }

    func testLineThicknessValidationAcceptsHalfPointValues() {
        var preferences = AppPreferences.default
        preferences.pinnedLineThickness = 2.5
        preferences.guidelineLineThickness = 10
        let validated = preferences.validated()
        XCTAssertEqual(validated.pinnedLineThickness, 2.5)
        XCTAssertEqual(validated.guidelineLineThickness, 10)
        XCTAssertEqual(validated.measurementLineThickness, 1)
        XCTAssertEqual(validated.rectangleLineThickness, 1)
    }

    func testShortcutNormalizationRequiresSingleAlphanumericAndModifier() {
        XCTAssertEqual(
            ShortcutConfiguration(key: " f ", modifiers: [.command, .shift]).normalized(),
            .default
        )
        XCTAssertNil(ShortcutConfiguration(key: "FF", modifiers: [.command]).normalized())
        XCTAssertNil(ShortcutConfiguration(key: "F", modifiers: []).normalized())
    }
}
