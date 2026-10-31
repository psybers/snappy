import AppKit
import CoreGraphics
import XCTest

@MainActor
final class ScreenCaptureDetectionTests: XCTestCase {
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
