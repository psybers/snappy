import XCTest

/// Tests for `PreferencesStore.swift` — UserDefaults-backed persistence,
/// validation, and edge-tolerance stepping/nudging behavior.
final class PreferencesStoreTests: XCTestCase {
    func testToleranceOverridesPersistAndRejectInvalidValues() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = PreferencesStore(defaults: defaults)
        store.setEdgeToleranceValue(3, for: .low)
        store.setEdgeToleranceValue(10, for: .medium)
        store.setEdgeToleranceValue(25, for: .high)
        store.setEdgeToleranceLevel(.high)
        let restored = PreferencesStore(defaults: defaults)
        XCTAssertEqual(restored.preferences.edgeTolerance,
                       EdgeToleranceSettings(level: .high, low: 3, medium: 10, high: 25))
        store.setEdgeToleranceValue(300, for: .medium)
        XCTAssertNotNil(store.validationMessage)
        XCTAssertEqual(store.preferences.edgeTolerance.medium, 10)
        store.setEdgeToleranceValue(0, for: .zero)
        XCTAssertEqual(store.preferences.edgeTolerance.value, 25)
    }

    func testTemporaryToleranceNudgesWithoutPersisting() {
        let suiteName = "SnappyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        store.adjustTemporaryEdgeTolerance(by: 1)
        XCTAssertEqual(store.preferences.edgeTolerance.value, 9)
        XCTAssertEqual(store.preferences.edgeTolerance.level, .medium)
        XCTAssertEqual(store.preferences.edgeTolerance.temporaryValue, 9)

        // Landing back on the Medium preset stops tracking a temporary value.
        store.adjustTemporaryEdgeTolerance(by: -1)
        XCTAssertEqual(store.preferences.edgeTolerance.value, 8)
        XCTAssertNil(store.preferences.edgeTolerance.temporaryValue)
        XCTAssertEqual(store.preferences.edgeTolerance.level, .medium)

        // The nudge is session-only: a fresh store on the same defaults
        // never sees it, even after unrelated preference writes.
        store.adjustTemporaryEdgeTolerance(by: 3)
        store.setMeasurementColor(.measurementDefault)
        let restored = PreferencesStore(defaults: defaults)
        XCTAssertNil(restored.preferences.edgeTolerance.temporaryValue)
        XCTAssertEqual(restored.preferences.edgeTolerance.value, 8)

        // Bounds clamp at 0 and 100; hitting a preset reselects it.
        store.setEdgeToleranceLevel(.zero)
        store.adjustTemporaryEdgeTolerance(by: -5)
        XCTAssertEqual(store.preferences.edgeTolerance.value, 0)
        XCTAssertEqual(store.preferences.edgeTolerance.level, .zero)
        for _ in 0..<120 { store.adjustTemporaryEdgeTolerance(by: 1) }
        XCTAssertEqual(store.preferences.edgeTolerance.value, 100)
        XCTAssertEqual(store.preferences.edgeTolerance.temporaryValue, 100)

        // Choosing a preset level or editing preset values clears the nudge.
        store.setEdgeToleranceLevel(.low)
        XCTAssertNil(store.preferences.edgeTolerance.temporaryValue)
        store.adjustTemporaryEdgeTolerance(by: 2)
        store.setEdgeToleranceValue(6, for: .low)
        XCTAssertNil(store.preferences.edgeTolerance.temporaryValue)
    }

    func testPresetStepFromTemporaryValueJumpsToBracketingPreset() {
        let suiteName = "SnappyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        // Medium=32, High=54; select High then nudge down to 48.
        store.setEdgeToleranceValue(54, for: .high)
        store.setEdgeToleranceValue(32, for: .medium)
        store.setEdgeToleranceLevel(.high)
        for _ in 0..<6 { store.adjustTemporaryEdgeTolerance(by: -1) }
        XCTAssertEqual(store.preferences.edgeTolerance.value, 48)
        XCTAssertEqual(store.preferences.edgeTolerance.temporaryValue, 48)

        // '-' jumps to the preset below the nudge, '=' to the one above.
        store.stepEdgeTolerance(by: -1, wrapping: false)
        XCTAssertEqual(store.preferences.edgeTolerance.level, .medium)
        XCTAssertEqual(store.preferences.edgeTolerance.value, 32)
        XCTAssertNil(store.preferences.edgeTolerance.temporaryValue)

        store.setEdgeToleranceLevel(.high)
        for _ in 0..<6 { store.adjustTemporaryEdgeTolerance(by: -1) }
        store.stepEdgeTolerance(by: 1, wrapping: false)
        XCTAssertEqual(store.preferences.edgeTolerance.level, .high)
        XCTAssertEqual(store.preferences.edgeTolerance.value, 54)
        XCTAssertNil(store.preferences.edgeTolerance.temporaryValue)

        // Without a nudge, stepping still moves the level index.
        store.stepEdgeTolerance(by: -1, wrapping: false)
        XCTAssertEqual(store.preferences.edgeTolerance.level, .medium)
        store.stepEdgeTolerance(by: 1, wrapping: true)
        XCTAssertEqual(store.preferences.edgeTolerance.level, .high)

        // Nudged above every preset: T still cycles levels and clears the nudge.
        store.setEdgeToleranceLevel(.high)
        for _ in 0..<10 { store.adjustTemporaryEdgeTolerance(by: 1) }
        XCTAssertEqual(store.preferences.edgeTolerance.temporaryValue, 64)
        store.stepEdgeTolerance(by: 0, wrapping: true)
        XCTAssertEqual(store.preferences.edgeTolerance.level, .zero)
        XCTAssertEqual(store.preferences.edgeTolerance.value, 0)
        XCTAssertNil(store.preferences.edgeTolerance.temporaryValue)

        // With no preset above the nudge, '=' is a no-op and keeps the nudge.
        store.setEdgeToleranceLevel(.high)
        for _ in 0..<10 { store.adjustTemporaryEdgeTolerance(by: 1) }
        store.stepEdgeTolerance(by: 1, wrapping: false)
        XCTAssertEqual(store.preferences.edgeTolerance.temporaryValue, 64)
        XCTAssertEqual(store.preferences.edgeTolerance.level, .high)
    }

    func testPreferencesStorePersistsUpdatesAndRejectsInvalidValues() {
        let suiteName = "SnappyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)
        let measurementColor = ColorComponents(red: 0.2, green: 0.3, blue: 0.4, opacity: 0.5)

        store.setShortcutKey("g")
        store.setMeasurementColor(measurementColor)
        store.setDimensionLabelFontSize(18)
        XCTAssertEqual(store.preferences.shortcut.key, "G")
        XCTAssertEqual(store.preferences.measurementColor, measurementColor)
        XCTAssertEqual(store.preferences.dimensionLabelFontSize, 18)
        XCTAssertEqual(
            PreferencesStore(defaults: defaults).preferences,
            store.preferences
        )

        store.setShortcutKey("bad")
        store.setDimensionLabelFontSize(100)
        XCTAssertEqual(store.preferences.shortcut.key, "G")
        XCTAssertEqual(store.preferences.dimensionLabelFontSize, 18)
        XCTAssertNotNil(store.validationMessage)
    }

    func testPinnedLineThicknessLockMirrorsMeasurementThickness() {
        let suiteName = "SnappyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        // Locked by default: moving the measurement slider moves pinned too.
        XCTAssertTrue(store.preferences.pinnedLineThicknessLocked)
        store.setLineThickness(4, for: \.measurementLineThickness)
        XCTAssertEqual(store.preferences.pinnedLineThickness, 4)

        // Unlocking keeps the synced value, then allows independent changes.
        store.setPinnedLineThicknessLocked(false)
        store.setLineThickness(7, for: \.pinnedLineThickness)
        store.setLineThickness(6, for: \.measurementLineThickness)
        XCTAssertEqual(store.preferences.pinnedLineThickness, 7)
        XCTAssertEqual(store.preferences.measurementLineThickness, 6)

        // Relocking snaps pinned back to the measurement value and persists.
        store.setPinnedLineThicknessLocked(true)
        XCTAssertEqual(store.preferences.pinnedLineThickness, 6)
        XCTAssertEqual(PreferencesStore(defaults: defaults).preferences.pinnedLineThickness, 6)
    }

    func testScopedResetsOnlyTouchTheirOwnSettings() {
        let suiteName = "SnappyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        // Customize one setting per tab.
        store.setShortcutKey("g")
        store.setModifier(.option, enabled: true)
        store.setEdgeToleranceValue(20, for: .low)
        store.setMeasurementColor(ColorComponents(red: 0.1, green: 0.2, blue: 0.3, opacity: 1))
        store.setDimensionLabelFontSize(24)
        store.setLineThickness(5, for: \.measurementLineThickness)
        store.setPinnedLineThicknessLocked(false)

        let customized = store.preferences

        // Shortcut reset leaves tolerance and appearance untouched.
        store.resetShortcutToDefaults()
        XCTAssertEqual(store.preferences.shortcut, .default)
        XCTAssertEqual(store.preferences.edgeTolerance, customized.edgeTolerance)
        XCTAssertEqual(store.preferences.measurementColor, customized.measurementColor)
        XCTAssertEqual(store.preferences.dimensionLabelFontSize, customized.dimensionLabelFontSize)
        XCTAssertEqual(store.preferences.measurementLineThickness, customized.measurementLineThickness)

        // Tolerance reset restores presets and clears any temporary nudge.
        store.adjustTemporaryEdgeTolerance(by: 3)
        XCTAssertNotNil(store.preferences.edgeTolerance.temporaryValue)
        store.resetEdgeToleranceToDefaults()
        XCTAssertEqual(store.preferences.edgeTolerance, EdgeToleranceSettings())
        XCTAssertEqual(store.preferences.shortcut, .default)
        XCTAssertEqual(store.preferences.measurementColor, customized.measurementColor)

        // Appearance reset restores colors, label size, thicknesses, and lock.
        store.resetAppearanceToDefaults()
        XCTAssertEqual(store.preferences.measurementColor, .measurementDefault)
        XCTAssertEqual(store.preferences.guidelineColor, .guidelineDefault)
        XCTAssertEqual(store.preferences.dimensionLabelFontSize, AppPreferences.default.dimensionLabelFontSize)
        XCTAssertEqual(store.preferences.measurementLineThickness, 1)
        XCTAssertEqual(store.preferences.pinnedLineThickness, 1)
        XCTAssertEqual(store.preferences.guidelineLineThickness, 1)
        XCTAssertEqual(store.preferences.rectangleLineThickness, 1)
        XCTAssertTrue(store.preferences.pinnedLineThicknessLocked)
        XCTAssertEqual(store.preferences.shortcut, .default)

        // Every reset persisted through UserDefaults.
        let restored = PreferencesStore(defaults: defaults)
        XCTAssertEqual(restored.preferences, store.preferences)
    }

    func testPreferencesStoreReportsCorruptSavedData() {
        let suiteName = "SnappyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "snappy.preferences.v1")

        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.preferences, .default)
        XCTAssertNotNil(store.persistenceError)
    }
}
