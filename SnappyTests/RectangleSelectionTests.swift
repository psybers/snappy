import CoreGraphics
import XCTest

@testable import Snappy

final class RectangleSelectionTests: XCTestCase {
    func testClipToDisplay() {
        let display = Rect2D(x: 0, y: 0, width: 100, height: 100)
        let clipped = SelectionGeometry.clip(Rect2D(x: 50, y: 50, width: 100, height: 100), to: display)
        XCTAssertEqual(clipped, Rect2D(x: 50, y: 50, width: 50, height: 50))
        XCTAssertNil(SelectionGeometry.clip(Rect2D(x: 200, y: 0, width: 10, height: 10), to: display))
    }

    func testSamplePoints() {
        let points = SelectionGeometry.samplePoints(in: Rect2D(x: 0, y: 0, width: 10, height: 10), columns: 2, rows: 2)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.first, Point2D(x: 2.5, y: 2.5))
        XCTAssertTrue(SelectionGeometry.samplePoints(in: Rect2D(x: 0, y: 0, width: 0, height: 0), columns: 2, rows: 2).isEmpty)
    }

    func testEnclosingUnionsIntersectingAndContainedOnly() {
        let selection = Rect2D(x: 10, y: 10, width: 50, height: 50)
        let contained = Rect2D(x: 20, y: 20, width: 10, height: 10)
        let straddling = Rect2D(x: 50, y: 40, width: 40, height: 10)
        let outside = Rect2D(x: 200, y: 200, width: 10, height: 10)
        let touching = Rect2D(x: 60, y: 10, width: 10, height: 10)
        let result = SelectionGeometry.enclosing(
            selection: selection, elements: [contained, straddling, outside, touching])
        XCTAssertEqual(result, Rect2D(x: 20, y: 20, width: 70, height: 30))
        XCTAssertNil(SelectionGeometry.enclosing(selection: selection, elements: [outside]))
    }

    private func image(width: Int, height: Int, square: (x: Int, y: Int, w: Int, h: Int)?) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let s = square {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            // CGContext origin is bottom-left; y here is measured from the bottom.
            ctx.fill(CGRect(x: s.x, y: s.y, width: s.w, height: s.h))
        }
        return ctx.makeImage()!
    }

    func testContentBoundsFindsSquare() {
        let captured = CapturedDisplayRegion(
            image: image(width: 100, height: 100, square: (20, 30, 40, 10)),
            displayID: "d", displayLocalBounds: Rect2D(x: 100, y: 200, width: 100, height: 100))
        let bounds = ContentBoundsDetector().bounds(in: captured)
        XCTAssertEqual(bounds, Rect2D(x: 120, y: 230, width: 40, height: 10))
    }

    func testContentBoundsScale2() {
        let captured = CapturedDisplayRegion(
            image: image(width: 100, height: 100, square: (20, 30, 40, 10)),
            displayID: "d", displayLocalBounds: Rect2D(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(
            ContentBoundsDetector().bounds(in: captured), Rect2D(x: 10, y: 15, width: 20, height: 5))
    }

    func testContentBoundsEmpty() {
        let captured = CapturedDisplayRegion(
            image: image(width: 40, height: 40, square: nil),
            displayID: "d", displayLocalBounds: Rect2D(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNil(ContentBoundsDetector().bounds(in: captured))
    }

    func testRectangleLabelAndHitTesting() {
        let rect = Rect2D(x: 100, y: 100, width: 80, height: 60)
        let annotation = MeasurementAnnotation(displayID: "d", geometry: .rectangle(rect))
        XCTAssertEqual(AnnotationLayout.labelText(for: annotation.geometry), "80 × 60 pt")
        XCTAssertTrue(AnnotationHitTester.onOutline(Point2D(x: 100, y: 130), of: rect, tolerance: 4))
        XCTAssertFalse(AnnotationHitTester.onOutline(Point2D(x: 140, y: 130), of: rect, tolerance: 4))
    }

    func testRectangleLabelInsideWhenLargeBelowWhenSmall() {
        let large = Rect2D(x: 100, y: 100, width: 200, height: 100)
        let inside = AnnotationLayout.labelRect(for: .rectangle(large), fontSize: 12)!
        XCTAssertTrue(large.contains(Point2D(x: inside.minX, y: inside.minY)))
        XCTAssertTrue(large.contains(Point2D(x: inside.maxX, y: inside.maxY)))
        let small = Rect2D(x: 100, y: 100, width: 20, height: 10)
        let below = AnnotationLayout.labelRect(for: .rectangle(small), fontSize: 12)!
        XCTAssertLessThanOrEqual(below.maxY, small.minY)
    }

    func testSelectionRectNormalisesDrag() {
        let r = RectangleSelectionController.rect(from: Point2D(x: 50, y: 40), to: Point2D(x: 10, y: 90))
        XCTAssertEqual(r, Rect2D(x: 10, y: 40, width: 40, height: 50))
    }
}
