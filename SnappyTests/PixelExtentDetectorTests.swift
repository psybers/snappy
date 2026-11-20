import AppKit
import CoreGraphics
import XCTest

@testable import Snappy

/// Tests for `PixelExtentDetector.swift` — color-transition extent scanning.
@MainActor
final class PixelExtentDetectorTests: XCTestCase {
    private func makeDisplay() -> DisplayDescriptor {
        makeTestDisplay(id: "cgdisplay-primary", height: 800, pixelHeight: 1600)
    }

    func testToleranceChangesWhichColorTransitionsAreEdges() async throws {
        let display = makeDisplay()
        let context = try TestImages.context(width: 320, height: 240)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        // A six-level contrast: visible at Zero/Low, ignored at Medium/High.
        context.setFillColor(CGColor(gray: 249.0 / 255, alpha: 1))
        context.fill(CGRect(x: 60, y: 50, width: 200, height: 140))
        let image = try XCTUnwrap(context.makeImage())
        let captured = CapturedDisplayRegion(image: image, displayID: display.id,
                                             displayLocalBounds: Rect2D(x: 0, y: 0, width: 320, height: 240))
        for threshold in [0, 4, 8, 16] {
            let detector = PixelExtentDetector(edgeThreshold: threshold)
            let result = try XCTUnwrap(detector.detect(in: captured, pointer: Point2D(x: 100, y: 100), display: display))
            XCTAssertEqual(result.bounds.minX, threshold < 6 ? 60 : 0, accuracy: 1.5)
            XCTAssertEqual(result.bounds.maxX, threshold < 6 ? 260 : 320, accuracy: 1.5)
        }
        let capturer = StubRegionCapturer(result: .success(captured))
        var threshold = 4
        let service = ElementDetectionService(
            accessibilityClient: StubAccessibilityClient(element: nil), screenCapturer: capturer,
            visualDetector: VisualBoundaryDetector(), screenPermission: StubScreenPermission(authorized: true),
            minimumCaptureInterval: 0.12, captureRegionSize: display.logicalBounds.size,
            extentDetector: PixelExtentDetector(), accessibilityFirst: false, edgeTolerance: { threshold })
        for value in [4, 16] {
            threshold = value
            let result = await service.detect(at: Point2D(x: 160, y: 120), displays: [display],
                                              primaryDisplayBounds: display.logicalBounds)
            guard case .detected(let candidate) = result else { return XCTFail("Expected an edge result") }
            XCTAssertEqual(candidate.bounds.minX, value == 4 ? 60 : 0, accuracy: 1.5)
        }
        XCTAssertEqual(capturer.captureCount, 1, "Tolerance changes should reuse captured pixels")
    }

    func testPixelExtentDetectorFindsUniformAreaAroundPointer() throws {
        let display = makeDisplay()
        let region = Rect2D(x: 0, y: 0, width: 320, height: 240)
        let context = try TestImages.context(width: 320, height: 240)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // Dark frame: x 40...279, y 30...209 (bottom-left origin) leaves a white inner area.
        context.fill(CGRect(x: 40, y: 30, width: 240, height: 180))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 60, y: 50, width: 200, height: 140))
        let image = try XCTUnwrap(context.makeImage())

        let candidate = try XCTUnwrap(
            PixelExtentDetector().detect(
                in: CapturedDisplayRegion(image: image, displayID: display.id, displayLocalBounds: region),
                pointer: Point2D(x: 100, y: 100),
                display: display
            )
        )

        XCTAssertEqual(candidate.bounds.minX, 60, accuracy: 1.5)
        XCTAssertEqual(candidate.bounds.maxX, 260, accuracy: 1.5)
        XCTAssertEqual(candidate.bounds.minY, 50, accuracy: 1.5)
        XCTAssertEqual(candidate.bounds.maxY, 190, accuracy: 1.5)
    }

    func testThinLowContrastBordersAtBothScales() throws {
        for scale in [1, 2] {
            let display = makeDisplay()
            let context = try TestImages.context(width: 320 * scale, height: 240 * scale)
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            // A one-physical-pixel border, with less than the old threshold's contrast.
            context.setFillColor(CGColor(gray: 0.94, alpha: 1))
            context.fill(CGRect(x: 40, y: 30, width: 240, height: 180))
            let inset = 1.0 / Double(scale)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 40 + inset, y: 30 + inset,
                                width: 240 - 2 * inset, height: 180 - 2 * inset))
            let candidate = try XCTUnwrap(PixelExtentDetector().detect(
                in: CapturedDisplayRegion(image: XCTUnwrap(context.makeImage()),
                                          displayID: display.id,
                                          displayLocalBounds: Rect2D(x: 0, y: 0, width: 320, height: 240)),
                pointer: Point2D(x: 120.25, y: 100.25), display: display
            ))
            XCTAssertEqual(candidate.bounds.minX, 40 + inset, accuracy: 0.01)
            XCTAssertEqual(candidate.bounds.maxX, 280 - inset, accuracy: 0.01)
            XCTAssertEqual(candidate.bounds.minY, 30 + inset, accuracy: 0.01)
            XCTAssertEqual(candidate.bounds.maxY, 210 - inset, accuracy: 0.01)
        }
    }

    func testSoftLowContrastEdgeStopsAtStartOfTransition() throws {
        for scale in [1, 2] {
            let display = makeDisplay()
            let width = 320 * scale
            let height = 240 * scale
            let image = try TestImages.blankImage(width: width, height: height)
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            // Screenshot's dark control: 37 -> 42 -> 47. No adjacent
            // step exceeds 8, but the complete transition does.
            for row in 0..<height {
                let value: UInt8 = row < 150 * scale ? 37 : (row < 151 * scale ? 42 : 47)
                for x in 0..<width {
                    let index = (row * width + x) * 4
                    for channel in 0..<3 { pixels[index + channel] = value }
                }
            }
            let captured = CapturedDisplayRegion(image: image, displayID: display.id,
                                                 displayLocalBounds: Rect2D(x: 0, y: 0, width: 320, height: 240))
            let outside = try XCTUnwrap(PixelExtentDetector().detect(
                in: captured, pointer: Point2D(x: 160, y: 140), display: display, pixels: pixels
            ))
            XCTAssertEqual(outside.bounds.minY, 90, accuracy: 0.01)
            let inside = try XCTUnwrap(PixelExtentDetector().detect(
                in: captured, pointer: Point2D(x: 160, y: 40), display: display, pixels: pixels
            ))
            XCTAssertEqual(inside.bounds.maxY, 89, accuracy: 0.01)
        }
    }

    func testPixelScanIgnoresIsolatedNoiseAndReachesDisplayEdges() throws {
        let display = makeDisplay()
        let image = try TestImages.blankImage(width: 1000, height: 800)
        var pixels = try XCTUnwrap(PixelExtentDetector.rgbaPixels(of: image))
        let offset = (400 * 1000 + 600) * 4
        for channel in 0..<3 { pixels[offset + channel] = 0 }
        let candidate = try XCTUnwrap(PixelExtentDetector().detect(
            in: CapturedDisplayRegion(image: image, displayID: display.id,
                                      displayLocalBounds: display.logicalBounds),
            pointer: Point2D(x: 500.25, y: 400.25), display: display, pixels: pixels
        ))
        XCTAssertEqual(candidate.bounds, display.logicalBounds)
    }
}
