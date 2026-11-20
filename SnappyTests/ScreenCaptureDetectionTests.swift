import AppKit
import CoreGraphics
import XCTest

@testable import Snappy

/// Tests for `ScreenCaptureDetection.swift`: `CapturedDisplayRegion`
/// cropping, `ScreenCaptureKitRegionCapturer`, `VisualBoundaryDetector`,
/// and `ElementDetectionService` fallback orchestration.
@MainActor
final class ScreenCaptureDetectionTests: XCTestCase {
    func testRegionCaptureUsesScreenCaptureKitDespiteNegativeLegacyPermissionCheck() async throws {
        let permission = StubScreenPermission(authorized: false)
        let display = DisplayDescriptor(
            id: "cgdisplay-123",
            logicalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 800),
            pixelWidth: 2000,
            pixelHeight: 1600,
            backingScale: 2
        )
        let image = try TestImages.blankImage(width: 2000, height: 1600)
        var requestedDisplayID: UInt32?
        let capturer = ScreenCaptureKitRegionCapturer(permissionManager: permission) { displayID in
            requestedDisplayID = displayID
            return image
        }
        let region = Rect2D(x: 200, y: 50, width: 400, height: 300)

        let captured = try await capturer.capture(region: region, on: display)

        XCTAssertFalse(permission.isAuthorized)
        XCTAssertEqual(requestedDisplayID, 123)
        XCTAssertEqual(captured.displayLocalBounds, region)
        XCTAssertEqual(captured.image.width, 800)
        XCTAssertEqual(captured.image.height, 600)
    }

    func testFullDisplayCaptureIsCroppedBeforePointerDetection() throws {
        for scale in [1, 2] {
            let display = DisplayDescriptor(
                id: "cgdisplay-test",
                logicalBounds: Rect2D(x: -1000, y: 500, width: 1000, height: 800),
                pixelWidth: 1000 * scale,
                pixelHeight: 800 * scale,
                backingScale: Double(scale)
            )
            let context = try TestImages.context(width: 1000 * scale, height: 800 * scale)
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 300, y: 100, width: 160, height: 80))

            let region = Rect2D(x: 200, y: 50, width: 400, height: 300)
            let captured = try CapturedDisplayRegion.cropping(
                XCTUnwrap(context.makeImage()), to: region, on: display
            )
            XCTAssertEqual(captured.image.width, 400 * scale)
            XCTAssertEqual(captured.image.height, 300 * scale)
            XCTAssertEqual(captured.displayLocalBounds, region)
            let candidate = try XCTUnwrap(PixelExtentDetector().detect(
                in: captured, pointer: Point2D(x: 350, y: 140), display: display
            ))
            XCTAssertEqual(candidate.bounds.minX, 300, accuracy: 1.5)
            XCTAssertEqual(candidate.bounds.maxX, 460, accuracy: 1.5)
            XCTAssertEqual(candidate.bounds.minY, 100, accuracy: 1.5)
            XCTAssertEqual(candidate.bounds.maxY, 180, accuracy: 1.5)
        }
    }

    func testFractionalCropReportsPixelAlignedBounds() throws {
        let captured = try CapturedDisplayRegion.cropping(
            TestImages.blankImage(width: 2000, height: 1600),
            to: Rect2D(x: 200.2, y: 50.2, width: 400, height: 300),
            on: makeDisplay()
        )
        XCTAssertEqual(captured.image.width, 801)
        XCTAssertEqual(captured.image.height, 601)
        XCTAssertEqual(captured.displayLocalBounds, Rect2D(x: 200, y: 50, width: 400.5, height: 300.5))
    }

    func testLiveExtentCaptureReachesLargeElementBeyondCursorCrop() async throws {
        let display = DisplayDescriptor(
            id: "cgdisplay-large", logicalBounds: Rect2D(x: -2000, y: 400, width: 2000, height: 1200),
            pixelWidth: 2000, pixelHeight: 1200, backingScale: 1
        )
        let context = try TestImages.context(width: 2000, height: 1200)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1200))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 100, width: 1800, height: 1000))
        let capturer = StubRegionCapturer(result: .success(CapturedDisplayRegion(
            image: try XCTUnwrap(context.makeImage()), displayID: display.id,
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 2000, height: 1200)
        )))
        let service = ElementDetectionService(
            accessibilityClient: StubAccessibilityClient(element: nil), screenCapturer: capturer,
            visualDetector: VisualBoundaryDetector(), screenPermission: StubScreenPermission(authorized: true),
            minimumCaptureInterval: 0.12, captureRegionSize: Size2D(width: 1000, height: 700),
            extentDetector: PixelExtentDetector(), accessibilityFirst: false
        )
        let result = await service.detect(at: Point2D(x: -1000, y: 1000), displays: [display],
                                          primaryDisplayBounds: display.logicalBounds)
        guard case .detected(let candidate) = result else { return XCTFail("Expected a boundary") }
        XCTAssertEqual(capturer.lastRegion, Rect2D(x: 0, y: 0, width: 2000, height: 1200))
        XCTAssertEqual(candidate.bounds, Rect2D(x: 100, y: 100, width: 1800, height: 1000))
    }

    // MARK: - VisualBoundaryDetector

    func testVisualDetectorFindsPointerContainingRectangleInFixture() throws {
        let display = makeDisplay()
        let region = Rect2D(x: 0, y: 0, width: 320, height: 240)
        let image = try TestImages.rectangleImage(width: 640, height: 480)
        let capture = CapturedDisplayRegion(
            image: image,
            displayID: display.id,
            displayLocalBounds: region
        )

        let candidates = try VisualBoundaryDetector().detect(
            in: capture,
            pointer: Point2D(x: 160, y: 120),
            display: display
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.source == .vision && $0.bounds.contains(Point2D(x: 160, y: 120)) })
        XCTAssertEqual(candidates, VisualBoundaryDetector.ranked(candidates, containing: Point2D(x: 160, y: 120)))
    }

    func testVisualDetectorReturnsNoCandidatesForBlankFixture() throws {
        let display = makeDisplay()
        let capture = CapturedDisplayRegion(
            image: try TestImages.blankImage(width: 160, height: 120),
            displayID: display.id,
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 320, height: 240)
        )

        XCTAssertTrue(
            try VisualBoundaryDetector().detect(
                in: capture,
                pointer: Point2D(x: 160, y: 120),
                display: display
            ).isEmpty
        )
    }

    func testRankingPrefersSmallestPointerContainingCandidateThenConfidence() {
        let pointer = Point2D(x: 50, y: 50)
        let large = candidate(x: 0, y: 0, width: 100, height: 100, confidence: 0.99)
        let smallLowConfidence = candidate(x: 40, y: 40, width: 20, height: 20, confidence: 0.7)
        let smallHighConfidence = candidate(x: 40, y: 40, width: 20, height: 20, confidence: 0.9)
        let unrelated = candidate(x: 200, y: 200, width: 20, height: 20, confidence: 1)

        XCTAssertEqual(
            VisualBoundaryDetector.ranked(
                [large, unrelated, smallLowConfidence, smallHighConfidence],
                containing: pointer
            ),
            [smallHighConfidence, smallLowConfidence, large]
        )
    }

    // MARK: - ElementDetectionService

    func testAccessibilityResultTakesPrecedenceWithoutScreenCapturePermission() async {
        let permission = StubScreenPermission(authorized: false)
        let capturer = StubRegionCapturer()
        let service = makeService(
            accessibilityElement: AccessibilityElementSnapshot(
                position: Point2D(x: 100, y: 100),
                size: Size2D(width: 200, height: 100),
                role: "AXButton"
            ),
            permission: permission,
            capturer: capturer
        )

        let result = await service.detect(
            at: Point2D(x: 150, y: 650),
            displays: [makeDisplay()],
            primaryDisplayBounds: makeDisplay().logicalBounds,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(result, .detected(candidate(
            x: 100,
            y: 600,
            width: 200,
            height: 100,
            confidence: 0.9,
            source: .accessibility,
            elementRole: "AXButton"
        )))
        XCTAssertEqual(capturer.captureCount, 0)
    }

    func testCapturerPermissionDeniedIsReportedEvenWhenPreflightIsFalse() async {
        let permission = StubScreenPermission(authorized: false)
        let capturer = StubRegionCapturer(
            result: .failure(ScreenCaptureError.permissionDenied)
        )
        let service = makeService(
            accessibilityElement: nil,
            permission: permission,
            capturer: capturer
        )

        let result = await service.detect(
            at: Point2D(x: 150, y: 650),
            displays: [makeDisplay()],
            primaryDisplayBounds: makeDisplay().logicalBounds,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(result, .unavailable(.screenCapturePermissionDenied))
        XCTAssertEqual(capturer.captureCount, 1)
    }

    func testFallbackCapturesOnlyBoundedPointerRegionAndThrottlesRapidRequests() async {
        let permission = StubScreenPermission(authorized: true)
        let capturer = StubRegionCapturer(
            result: .failure(ScreenCaptureError.displayUnavailable)
        )
        let service = makeService(
            accessibilityElement: nil,
            permission: permission,
            capturer: capturer
        )
        let display = makeDisplay()

        let first = await service.detect(
            at: Point2D(x: 990, y: 790),
            displays: [display],
            primaryDisplayBounds: display.logicalBounds,
            now: Date(timeIntervalSince1970: 100)
        )
        let second = await service.detect(
            at: Point2D(x: 990, y: 790),
            displays: [display],
            primaryDisplayBounds: display.logicalBounds,
            now: Date(timeIntervalSince1970: 100.05)
        )

        XCTAssertEqual(first, .unavailable(.screenCaptureFailed))
        XCTAssertEqual(second, .unavailable(.captureThrottled))
        XCTAssertEqual(capturer.captureCount, 1)
        XCTAssertEqual(capturer.lastRegion, Rect2D(x: 680, y: 560, width: 320, height: 240))
    }

    func testFallbackReturnsVisionCandidateFromBoundedCapture() async throws {
        let display = makeDisplay()
        let region = Rect2D(x: 340, y: 280, width: 320, height: 240)
        let capture = CapturedDisplayRegion(
            image: try TestImages.rectangleImage(width: 640, height: 480),
            displayID: display.id,
            displayLocalBounds: region
        )
        let permission = StubScreenPermission(authorized: true)
        let capturer = StubRegionCapturer(result: .success(capture))
        let service = makeService(
            accessibilityElement: nil,
            permission: permission,
            capturer: capturer
        )

        let result = await service.detect(
            at: Point2D(x: 500, y: 400),
            displays: [display],
            primaryDisplayBounds: display.logicalBounds,
            now: Date(timeIntervalSince1970: 100)
        )

        guard case .detected(let candidate) = result else {
            return XCTFail("Expected a vision boundary candidate, got \(result)")
        }
        XCTAssertEqual(candidate.source, .vision)
        XCTAssertEqual(candidate.displayID, display.id)
        XCTAssertTrue(candidate.bounds.contains(Point2D(x: 500, y: 400)))
    }

    // MARK: - Helpers

    private func makeService(
        accessibilityElement: AccessibilityElementSnapshot?,
        permission: StubScreenPermission,
        capturer: StubRegionCapturer
    ) -> ElementDetectionService {
        ElementDetectionService(
            accessibilityClient: StubAccessibilityClient(element: accessibilityElement),
            screenCapturer: capturer,
            visualDetector: VisualBoundaryDetector(),
            screenPermission: permission,
            minimumCaptureInterval: 0.12,
            captureRegionSize: Size2D(width: 320, height: 240)
        )
    }

    private func makeDisplay() -> DisplayDescriptor {
        makeTestDisplay(id: "cgdisplay-primary", height: 800, pixelHeight: 1600)
    }

    private func candidate(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        confidence: Double,
        source: DetectionSource = .vision,
        elementRole: String? = nil
    ) -> DetectionCandidate {
        DetectionCandidate(
            bounds: Rect2D(x: x, y: y, width: width, height: height),
            source: source,
            confidence: confidence,
            displayID: "cgdisplay-primary",
            elementRole: elementRole
        )
    }
}
