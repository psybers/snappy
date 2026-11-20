import AppKit
import XCTest

@testable import Snappy

/// Tests for `OverlayContentView.swift` — `TemporaryMeasurementOverlayView`
/// content/dimension-label behavior and `TemporaryDimensionLabels` placement.
@MainActor
final class OverlayContentViewTests: XCTestCase {
    func testToastCanBeReplacedAndDismissed() {
        let view = TemporaryMeasurementOverlayView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.setToast("Tolerance: Low (4)")
        XCTAssertEqual(view.toastText, "Tolerance: Low (4)")
        view.setToast("Tolerance: Medium (8)")
        XCTAssertEqual(view.toastText, "Tolerance: Medium (8)")
        view.setToast(nil)
        XCTAssertNil(view.toastText)
    }

    func testTemporaryOverlayAcceptsOnlyMatchingDisplayCandidates() {
        let view = TemporaryMeasurementOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 800)
        )
        let preferences = AppPreferences.default
        let candidate = DetectionCandidate(
            bounds: Rect2D(x: 20, y: 30, width: 200, height: 100),
            source: .accessibility,
            confidence: 0.9,
            displayID: "display-a"
        )

        view.update(
            .detected(candidate),
            pointer: Point2D(x: 50, y: 50),
            displayID: "display-a",
            preferences: preferences
        )

        XCTAssertEqual(view.content, .measurement(candidate, Point2D(x: 50, y: 50), preferences))
        XCTAssertEqual(
            view.dimensionLabels,
            TemporaryDimensionLabels(text: "200 × 100 pt")
        )

        view.update(
            .detected(candidate),
            pointer: Point2D(x: 50, y: 50),
            displayID: "display-b",
            preferences: preferences
        )

        XCTAssertNil(view.content)
        XCTAssertNil(view.dimensionLabels)
    }

    func testCrosshairPresentationNeedsNoDetectedElement() {
        let view = TemporaryMeasurementOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let pointer = Point2D(x: 80, y: 90)
        view.updateCrosshair(pointer: pointer, preferences: .default)
        XCTAssertEqual(view.content, .crosshair(pointer, .default))
        XCTAssertNil(view.dimensionLabels)
        view.clear()
        XCTAssertNil(view.content)
    }

    func testLabelPrefersBottomRightAndFlipsNearEdges() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 100, height: 20)
        let normal = TemporaryDimensionLabels.origin(pointer: NSPoint(x: 500, y: 400), labelSize: size, in: bounds)
        XCTAssertGreaterThan(normal.x, 500)
        XCTAssertLessThan(normal.y, 400)
        let right = TemporaryDimensionLabels.origin(pointer: NSPoint(x: 990, y: 400), labelSize: size, in: bounds)
        XCTAssertLessThan(right.x + size.width, 990)
        let bottom = TemporaryDimensionLabels.origin(pointer: NSPoint(x: 500, y: 5), labelSize: size, in: bounds)
        XCTAssertGreaterThan(bottom.y, 5)
    }
}
