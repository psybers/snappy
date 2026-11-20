import AppKit
import CoreGraphics
import XCTest

@testable import Snappy

/// Tests for `GuidelineSnapImage.swift` — sustained-edge detection used
/// while dragging annotations.
final class GuidelineSnapImageTests: XCTestCase {
    func testGuidelineSnappingStrengthOrientationScalingAndRelease() throws {
        for scale in [1, 2] {
            for axis in [AnnotationAxis.horizontal, .vertical] {
                func fixture(contrast: Int) throws -> GuidelineSnapImage {
                    let context = try TestImages.context(width: 320 * scale, height: 240 * scale)
                    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
                    context.setFillColor(CGColor(gray: Double(255 - contrast) / 255, alpha: 1))
                    context.fill(axis == .vertical
                        ? CGRect(x: 160, y: 0, width: 160, height: 240)
                        : CGRect(x: 0, y: 120, width: 320, height: 120))
                    return try XCTUnwrap(GuidelineSnapImage(CapturedDisplayRegion(
                        image: XCTUnwrap(context.makeImage()), displayID: "test",
                        displayLocalBounds: Rect2D(x: 0, y: 0, width: 320, height: 240))))
                }
                let coordinate = axis == .vertical ? 160.0 : 120.0
                func pointer(_ position: Double) -> Point2D {
                    axis == .vertical ? Point2D(x: position, y: 120) : Point2D(x: 160, y: position)
                }
                let strong = try fixture(contrast: 100)
                let weak = try fixture(contrast: 12)
                let near = try XCTUnwrap(weak.edge(axis: axis, position: coordinate - 2,
                    pointer: pointer(coordinate - 2), tolerance: 8, holding: nil))
                XCTAssertEqual(near.position, coordinate, accuracy: 1 / Double(scale))
                XCTAssertNil(weak.edge(axis: axis, position: coordinate - 10,
                    pointer: pointer(coordinate - 10), tolerance: 8, holding: nil))
                let snap = try XCTUnwrap(strong.edge(axis: axis, position: coordinate - 10,
                    pointer: pointer(coordinate - 10), tolerance: 8, holding: nil))
                XCTAssertGreaterThan(snap.strength, near.strength)
                XCTAssertGreaterThan(snap.radius, near.radius)
                let held = strong.edge(axis: axis, position: coordinate - 18,
                    pointer: pointer(coordinate - 18), tolerance: 8, holding: snap)
                XCTAssertEqual(held?.position, snap.position)
                XCTAssertNil(strong.edge(axis: axis, position: coordinate - 30,
                    pointer: pointer(coordinate - 30), tolerance: 8, holding: snap))
                XCTAssertNil(weak.edge(axis: axis, position: coordinate - 2,
                    pointer: pointer(coordinate - 2), tolerance: 20, holding: nil))
                let subtle = try fixture(contrast: 1)
                XCTAssertNotNil(subtle.edge(axis: axis, position: coordinate - 1,
                    pointer: pointer(coordinate - 1), tolerance: 0, holding: nil))
                XCTAssertNil(subtle.edge(axis: axis, position: coordinate - 1,
                    pointer: pointer(coordinate - 1), tolerance: 8, holding: nil))
            }
        }
    }
}
