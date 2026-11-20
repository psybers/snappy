import XCTest

/// Tests for `DisplayCoordinateMapper.swift` — global ↔ display-local ↔
/// Accessibility ↔ capture-pixel coordinate conversion.
final class DisplayCoordinateMapperTests: XCTestCase {
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
}
