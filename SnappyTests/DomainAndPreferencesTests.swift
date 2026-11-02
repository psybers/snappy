import XCTest

final class DomainAndPreferencesTests: XCTestCase {
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

    func testDisplayCoordinatesRoundTripWithNegativeOrigin() {
        let display = Rect2D(x: -1920, y: 120, width: 1920, height: 1080)
        let global = Point2D(x: -1810, y: 250)

        let local = DisplayCoordinateMapper.globalToDisplayLocal(global, displayBounds: display)

        XCTAssertEqual(local, Point2D(x: 110, y: 130))
        XCTAssertEqual(
            DisplayCoordinateMapper.displayLocalToGlobal(local, displayBounds: display),
            global
        )
    }

    func testRectangleCoordinatesRoundTripPreservesDimensions() {
        let display = Rect2D(x: -1600, y: -200, width: 1600, height: 900)
        let globalRect = Rect2D(x: -1530, y: 30, width: 125, height: 40)

        let local = DisplayCoordinateMapper.globalToDisplayLocal(
            globalRect,
            displayBounds: display
        )

        XCTAssertEqual(local, Rect2D(x: 70, y: 230, width: 125, height: 40))
        XCTAssertEqual(
            DisplayCoordinateMapper.displayLocalToGlobal(local, displayBounds: display),
            globalRect
        )
    }

    func testAccessibilityCoordinatesFlipVerticalAxisAtPrimaryDisplayTop() {
        let primaryDisplay = Rect2D(x: 0, y: 0, width: 1440, height: 900)
        let appKitPoint = Point2D(x: -300, y: 120)

        let accessibilityPoint = DisplayCoordinateMapper.appKitGlobalToAccessibility(
            appKitPoint,
            primaryDisplayBounds: primaryDisplay
        )

        XCTAssertEqual(accessibilityPoint, Point2D(x: -300, y: 780))
        XCTAssertEqual(
            DisplayCoordinateMapper.accessibilityToAppKitGlobal(
                accessibilityPoint,
                primaryDisplayBounds: primaryDisplay
            ),
            appKitPoint
        )
    }

    func testAccessibilityRectangleConversionUsesTopLeftOriginAndHeight() {
        let primaryDisplay = Rect2D(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertEqual(
            DisplayCoordinateMapper.accessibilityToAppKitGlobal(
                Rect2D(x: 120, y: 80, width: 300, height: 100),
                primaryDisplayBounds: primaryDisplay
            ),
            Rect2D(x: 120, y: 720, width: 300, height: 100)
        )
    }

    func testDisplayLocalPointAndRectangleMapToTopLeftCapturePixels() {
        let logicalSize = Size2D(width: 100, height: 50)
        let point = DisplayCoordinateMapper.displayLocalToCapturePixel(
            Point2D(x: 10, y: 5),
            logicalSize: logicalSize,
            pixelWidth: 200,
            pixelHeight: 150
        )
        let rect = DisplayCoordinateMapper.displayLocalToCapturePixel(
            Rect2D(x: 10, y: 5, width: 20, height: 10),
            logicalSize: logicalSize,
            pixelWidth: 200,
            pixelHeight: 150
        )

        XCTAssertEqual(point, Point2D(x: 20, y: 135))
        XCTAssertEqual(rect, Rect2D(x: 20, y: 105, width: 40, height: 30))
    }

    func testCaptureMappingRejectsOutOfBoundsAndInvalidGeometry() {
        XCTAssertNil(
            DisplayCoordinateMapper.displayLocalToCapturePixel(
                Point2D(x: 101, y: 5),
                logicalSize: Size2D(width: 100, height: 50),
                pixelWidth: 200,
                pixelHeight: 100
            )
        )
        XCTAssertNil(
            DisplayCoordinateMapper.displayLocalToCapturePixel(
                Rect2D(x: -1, y: 0, width: 10, height: 10),
                logicalSize: Size2D(width: 100, height: 50),
                pixelWidth: 200,
                pixelHeight: 100
            )
        )
    }

    func testRectangleUnionAndIntersection() {
        let first = Rect2D(x: -10, y: 5, width: 20, height: 10)
        let second = Rect2D(x: 5, y: 0, width: 10, height: 20)

        XCTAssertTrue(first.intersects(second))
        XCTAssertEqual(first.union(second), Rect2D(x: -10, y: 0, width: 25, height: 20))
    }

    func testDetectionCandidateRequiresUsableBoundsAndConfidence() {
        XCTAssertTrue(
            DetectionCandidate(
                bounds: Rect2D(x: 1, y: 2, width: 30, height: 40),
                source: .accessibility,
                confidence: 1
            ).isValid
        )
        XCTAssertFalse(
            DetectionCandidate(
                bounds: Rect2D(x: 1, y: 2, width: 0, height: 40),
                source: .vision,
                confidence: 0.9
            ).isValid
        )
        XCTAssertFalse(
            DetectionCandidate(
                bounds: Rect2D(x: 1, y: 2, width: 30, height: 40),
                source: .vision,
                confidence: 1.1
            ).isValid
        )
    }

    func testDisplayDescriptorValidatesGeometryAndScale() {
        XCTAssertTrue(
            DisplayDescriptor(
                id: "display-1",
                logicalBounds: Rect2D(x: -100, y: 0, width: 100, height: 80),
                pixelWidth: 200,
                pixelHeight: 160,
                backingScale: 2
            ).isValid
        )
        XCTAssertFalse(
            DisplayDescriptor(
                id: "display-2",
                logicalBounds: Rect2D(x: 0, y: 0, width: 100, height: 80),
                pixelWidth: 200,
                pixelHeight: 160,
                backingScale: 0
            ).isValid
        )
    }

    func testSessionAndAnnotationCodableRoundTrip() throws {
        let display = DisplayDescriptor(
            id: "display-1",
            logicalBounds: Rect2D(x: -100, y: 20, width: 100, height: 80),
            pixelWidth: 200,
            pixelHeight: 160,
            backingScale: 2
        )
        let session = MeasurementSession(
            id: UUID(uuidString: "D7DF3A31-016C-42AD-8D4B-7AA6B5A46E80")!,
            createdAt: Date(timeIntervalSince1970: 100),
            lastModifiedAt: Date(timeIntervalSince1970: 200),
            displays: [
                DisplayAnnotations(
                    display: display,
                    annotations: [
                        MeasurementAnnotation(
                            id: UUID(uuidString: "8C1171AC-7514-46CD-80AF-7CC45C039C66")!,
                            displayID: display.id,
                            geometry: .rectangle(Rect2D(x: 2, y: 3, width: 20, height: 10))
                        ),
                        MeasurementAnnotation(
                            displayID: display.id,
                            geometry: .guideline(axis: .vertical, position: 15)
                        )
                    ]
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            MeasurementSession.self,
            from: JSONEncoder().encode(session)
        )

        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.schemaVersion, MeasurementSession.currentSchemaVersion)
    }

    func testPreferencesDefaultsAndValidation() {
        XCTAssertEqual(AppPreferences.default.shortcut, .default)
        XCTAssertEqual(AppPreferences.default.measurementColor, .measurementDefault)
        XCTAssertEqual(AppPreferences.default.guidelineColor, .guidelineDefault)
        XCTAssertEqual(AppPreferences.default.dimensionLabelFontSize, 14)

        var invalid = AppPreferences.default
        invalid.shortcut = ShortcutConfiguration(key: "escape", modifiers: [.command])
        invalid.measurementColor.red = .infinity
        invalid.dimensionLabelFontSize = 100

        XCTAssertEqual(invalid.validated(), .default)
    }

    func testShortcutNormalizationRequiresSingleAlphanumericAndModifier() {
        XCTAssertEqual(
            ShortcutConfiguration(key: " f ", modifiers: [.command, .shift]).normalized(),
            .default
        )
        XCTAssertNil(ShortcutConfiguration(key: "FF", modifiers: [.command]).normalized())
        XCTAssertNil(ShortcutConfiguration(key: "F", modifiers: []).normalized())
    }

    func testCarbonKeyCodeMappingSupportsConfiguredLettersAndRejectsUnsupportedKey() {
        XCTAssertEqual(GlobalShortcutService.virtualKeyCode(for: "F"), 3)
        XCTAssertEqual(GlobalShortcutService.virtualKeyCode(for: "v"), 9)
        XCTAssertEqual(GlobalShortcutService.virtualKeyCode(for: "1"), 18)
        XCTAssertNil(GlobalShortcutService.virtualKeyCode(for: "SPACE"))
        XCTAssertNil(GlobalShortcutService.virtualKeyCode(for: "FF"))
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
