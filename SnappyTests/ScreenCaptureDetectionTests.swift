import AppKit
import CoreGraphics
import XCTest

@MainActor
final class ScreenCaptureDetectionTests: XCTestCase {
    func testGuidelineSnappingStrengthOrientationScalingAndRelease() throws {
        for scale in [1, 2] {
            for axis in [AnnotationAxis.horizontal, .vertical] {
                func fixture(contrast: Int) throws -> GuidelineSnapImage {
                    let context = try imageContext(width: 320 * scale, height: 240 * scale)
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

    func testToleranceChangesWhichColorTransitionsAreEdges() async throws {
        let display = makeDisplay()
        let context = try imageContext(width: 320, height: 240)
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
        let capturer = ScreenRegionCapturerStub(result: .success(captured))
        var threshold = 4
        let service = ElementDetectionService(
            accessibilityClient: AccessibilityClientStub(element: nil), screenCapturer: capturer,
            visualDetector: VisualBoundaryDetector(), screenPermission: ScreenPermissionStub(authorized: true),
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

    func testRegionCaptureUsesScreenCaptureKitDespiteNegativeLegacyPermissionCheck() async throws {
        let permission = ScreenPermissionStub(authorized: false)
        let display = DisplayDescriptor(
            id: "cgdisplay-123",
            logicalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 800),
            pixelWidth: 2000,
            pixelHeight: 1600,
            backingScale: 2
        )
        let image = try blankFixture(width: 2000, height: 1600)
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
            let context = try imageContext(width: 1000 * scale, height: 800 * scale)
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
            blankFixture(width: 2000, height: 1600),
            to: Rect2D(x: 200.2, y: 50.2, width: 400, height: 300),
            on: makeDisplay()
        )
        XCTAssertEqual(captured.image.width, 801)
        XCTAssertEqual(captured.image.height, 601)
        XCTAssertEqual(captured.displayLocalBounds, Rect2D(x: 200, y: 50, width: 400.5, height: 300.5))
    }

    func testPixelExtentDetectorFindsUniformAreaAroundPointer() throws {
        let display = makeDisplay()
        let region = Rect2D(x: 0, y: 0, width: 320, height: 240)
        let context = try imageContext(width: 320, height: 240)
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
            let context = try imageContext(width: 320 * scale, height: 240 * scale)
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
            let image = try blankFixture(width: width, height: height)
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
        let image = try blankFixture(width: 1000, height: 800)
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

    func testLiveExtentCaptureReachesLargeElementBeyondCursorCrop() async throws {
        let display = DisplayDescriptor(
            id: "cgdisplay-large", logicalBounds: Rect2D(x: -2000, y: 400, width: 2000, height: 1200),
            pixelWidth: 2000, pixelHeight: 1200, backingScale: 1
        )
        let context = try imageContext(width: 2000, height: 1200)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1200))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 100, width: 1800, height: 1000))
        let capturer = ScreenRegionCapturerStub(result: .success(CapturedDisplayRegion(
            image: try XCTUnwrap(context.makeImage()), displayID: display.id,
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 2000, height: 1200)
        )))
        let service = ElementDetectionService(
            accessibilityClient: AccessibilityClientStub(element: nil), screenCapturer: capturer,
            visualDetector: VisualBoundaryDetector(), screenPermission: ScreenPermissionStub(authorized: true),
            minimumCaptureInterval: 0.12, captureRegionSize: Size2D(width: 1000, height: 700),
            extentDetector: PixelExtentDetector(), accessibilityFirst: false
        )
        let result = await service.detect(at: Point2D(x: -1000, y: 1000), displays: [display],
                                          primaryDisplayBounds: display.logicalBounds)
        guard case .detected(let candidate) = result else { return XCTFail("Expected a boundary") }
        XCTAssertEqual(capturer.lastRegion, Rect2D(x: 0, y: 0, width: 2000, height: 1200))
        XCTAssertEqual(candidate.bounds, Rect2D(x: 100, y: 100, width: 1800, height: 1000))
    }

    func testVisualDetectorFindsPointerContainingRectangleInFixture() throws {
        let display = makeDisplay()
        let region = Rect2D(x: 0, y: 0, width: 320, height: 240)
        let image = try rectangleFixture(width: 640, height: 480)
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
            image: try blankFixture(width: 160, height: 120),
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

    func testAccessibilityResultTakesPrecedenceWithoutScreenCapturePermission() async {
        let permission = ScreenPermissionStub(authorized: false)
        let capturer = ScreenRegionCapturerStub()
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
        let permission = ScreenPermissionStub(authorized: false)
        let capturer = ScreenRegionCapturerStub(
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
        let permission = ScreenPermissionStub(authorized: true)
        let capturer = ScreenRegionCapturerStub(
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
            image: try rectangleFixture(width: 640, height: 480),
            displayID: display.id,
            displayLocalBounds: region
        )
        let permission = ScreenPermissionStub(authorized: true)
        let capturer = ScreenRegionCapturerStub(result: .success(capture))
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

    private func makeService(
        accessibilityElement: AccessibilityElementSnapshot?,
        permission: ScreenPermissionStub,
        capturer: ScreenRegionCapturerStub
    ) -> ElementDetectionService {
        ElementDetectionService(
            accessibilityClient: AccessibilityClientStub(element: accessibilityElement),
            screenCapturer: capturer,
            visualDetector: VisualBoundaryDetector(),
            screenPermission: permission,
            minimumCaptureInterval: 0.12,
            captureRegionSize: Size2D(width: 320, height: 240)
        )
    }

    private func makeDisplay() -> DisplayDescriptor {
        DisplayDescriptor(
            id: "cgdisplay-primary",
            logicalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 800),
            pixelWidth: 2000,
            pixelHeight: 1600,
            backingScale: 2
        )
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

    private func blankFixture(width: Int, height: Int) throws -> CGImage {
        let context = try imageContext(width: width, height: height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw FixtureError.imageCreationFailed
        }
        return image
    }

    private func rectangleFixture(width: Int, height: Int) throws -> CGImage {
        let context = try imageContext(width: width, height: height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(6)
        context.stroke(CGRect(x: 100, y: 100, width: 440, height: 280))
        guard let image = context.makeImage() else {
            throw FixtureError.imageCreationFailed
        }
        return image
    }

    private func imageContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FixtureError.contextCreationFailed
        }
        return context
    }

    private enum FixtureError: Error {
        case contextCreationFailed
        case imageCreationFailed
    }
}

@MainActor
private final class AccessibilityClientStub: AccessibilityElementQuerying {
    let isTrusted = true
    let result: AccessibilityElementSnapshot?

    init(element: AccessibilityElementSnapshot?) {
        result = element
    }

    func element(at accessibilityPoint: Point2D) -> AccessibilityElementSnapshot? {
        result
    }
}

@MainActor
private final class ScreenPermissionStub: ScreenCaptureAuthorizationChecking {
    var isAuthorized: Bool

    init(authorized: Bool) {
        isAuthorized = authorized
    }

    func refresh() -> Bool { isAuthorized }
    func requestPrompt() -> Bool { isAuthorized }
}

@MainActor
private final class ScreenRegionCapturerStub: ScreenRegionCapturing {
    private let result: Result<CapturedDisplayRegion, Error>
    private(set) var captureCount = 0
    private(set) var lastRegion: Rect2D?

    init(result: Result<CapturedDisplayRegion, Error> = .failure(ScreenCaptureError.displayUnavailable)) {
        self.result = result
    }

    func capture(region: Rect2D, on display: DisplayDescriptor) async throws -> CapturedDisplayRegion {
        captureCount += 1
        lastRegion = region
        return try result.get()
    }
}
