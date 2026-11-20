import AppKit
import CoreGraphics
import Foundation

// Shared fixtures and stubs for the test target. Test classes live in
// files named after the type they exercise; anything reused across files
// lives here so each test file stays focused on assertions.

// MARK: - Model fixtures

func makeTestDisplay(
    id: String = "test-display",
    x: Double = 0,
    y: Double = 0,
    width: Double = 1000,
    height: Double = 600,
    pixelWidth: Int = 2000,
    pixelHeight: Int = 1200,
    scale: Double = 2
) -> DisplayDescriptor {
    DisplayDescriptor(
        id: id,
        logicalBounds: Rect2D(x: x, y: y, width: width, height: height),
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        backingScale: scale
    )
}

func makeTestSession(display: DisplayDescriptor, annotationCount: Int = 1) -> MeasurementSession {
    MeasurementSession(
        displays: [
            DisplayAnnotations(
                display: display,
                annotations: (0..<annotationCount).map { _ in
                    MeasurementAnnotation(
                        displayID: display.id,
                        geometry: .horizontalMeasurement(
                            start: Point2D(x: 100, y: 200), length: 300)
                    )
                }
            )
        ]
    )
}

// MARK: - Image fixtures

enum TestImages {
    enum FixtureError: Error {
        case contextCreationFailed
        case imageCreationFailed
    }

    static func context(width: Int, height: Int) throws -> CGContext {
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

    static func blankImage(width: Int, height: Int) throws -> CGImage {
        let context = try context(width: width, height: height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw FixtureError.imageCreationFailed
        }
        return image
    }

    /// White field with a solid filled rectangle (nil = blank), used by
    /// `ContentBoundsDetector` tests. `rect` origin is bottom-left, matching
    /// CGContext coordinates.
    static func filledRectImage(
        width: Int, height: Int,
        rect: (x: Int, y: Int, w: Int, h: Int)?
    ) throws -> CGImage {
        let context = try context(width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let rect {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h))
        }
        guard let image = context.makeImage() else {
            throw FixtureError.imageCreationFailed
        }
        return image
    }

    /// White field with a black stroked rectangle, used by Vision tests.
    static func rectangleImage(width: Int, height: Int) throws -> CGImage {
        let context = try context(width: width, height: height)
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
}

// MARK: - Protocol stubs

@MainActor
final class StubAccessibilityClient: AccessibilityElementQuerying {
    var isTrusted: Bool
    var result: AccessibilityElementSnapshot?
    private(set) var lastPoint: Point2D?

    init(isTrusted: Bool = true, element: AccessibilityElementSnapshot? = nil) {
        self.isTrusted = isTrusted
        result = element
    }

    func element(at accessibilityPoint: Point2D) -> AccessibilityElementSnapshot? {
        lastPoint = accessibilityPoint
        return result
    }
}

@MainActor
final class StubScreenPermission: ScreenCaptureAuthorizationChecking {
    var isAuthorized: Bool

    init(authorized: Bool) {
        isAuthorized = authorized
    }

    func refresh() -> Bool { isAuthorized }
    func requestPrompt() -> Bool { isAuthorized }
}

@MainActor
final class StubRegionCapturer: ScreenRegionCapturing {
    private let result: Result<CapturedDisplayRegion, Error>
    private(set) var captureCount = 0
    private(set) var lastRegion: Rect2D?
    private(set) var requestedDisplays: [String] = []

    init(result: Result<CapturedDisplayRegion, Error> = .failure(ScreenCaptureError.displayUnavailable)) {
        self.result = result
    }

    func capture(region: Rect2D, on display: DisplayDescriptor) async throws -> CapturedDisplayRegion {
        captureCount += 1
        lastRegion = region
        requestedDisplays.append(display.id)
        return try result.get()
    }
}

/// Returns queued `(delay, result)` pairs in order, then `.unavailable`.
@MainActor
final class StubElementDetector: ElementDetecting {
    private(set) var callCount = 0
    private var responses: [(TimeInterval, ElementDetectionResult)]

    init(responses: [(TimeInterval, ElementDetectionResult)] = []) {
        self.responses = responses
    }

    func detect(
        at globalPointer: Point2D,
        displays: [DisplayDescriptor],
        primaryDisplayBounds: Rect2D,
        now: Date
    ) async -> ElementDetectionResult {
        callCount += 1
        guard !responses.isEmpty else { return .unavailable(.noConfidentBoundary) }
        let (delay, result) = responses.removeFirst()
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return result
    }
}

@MainActor
final class StubMeasurementPresenter: TemporaryMeasurementPresenting {
    private(set) var presentedResults: [ElementDetectionResult] = []
    private(set) var presentedPointers: [Point2D] = []
    private(set) var clearCount = 0
    private(set) var crosshairPointers: [Point2D] = []

    func showTemporaryMeasurement(
        _ result: ElementDetectionResult,
        at globalPointer: Point2D,
        preferences: AppPreferences
    ) {
        presentedResults.append(result)
        presentedPointers.append(globalPointer)
    }

    func showTemporaryCrosshair(at globalPointer: Point2D, preferences: AppPreferences) {
        crosshairPointers.append(globalPointer)
    }

    func clearTemporaryMeasurements() {
        clearCount += 1
    }
}

@MainActor
final class StubMeasurementDisplayProvider: MeasurementDisplayProviding {
    let connectedDisplays: [DisplayDescriptor]
    let primaryDisplayBounds: Rect2D?

    init(display: DisplayDescriptor) {
        connectedDisplays = [display]
        primaryDisplayBounds = display.logicalBounds
    }

    func showTemporaryMeasurement(
        _ result: ElementDetectionResult,
        at globalPointer: Point2D,
        preferences: AppPreferences
    ) {}

    func clearTemporaryMeasurements() {}

    func showTemporaryCrosshair(at globalPointer: Point2D, preferences: AppPreferences) {}
}

@MainActor
final class StubAnnotationSurface: AnnotationSurfacePresenting {
    var capture: CapturedDisplayRegion?

    func snappingCapture(for display: DisplayDescriptor) -> CapturedDisplayRegion? { capture }

    let connectedDisplays: [DisplayDescriptor]

    init(displays: [DisplayDescriptor]) {
        connectedDisplays = displays
    }

    func presentAnnotations(_ groups: [DisplayAnnotations], preferences: AppPreferences) {}
    func setAnnotationHover(_ hit: AnnotationHit?, onDisplay displayID: String?) {}
    func setAnnotationMouseHandler(_ handler: AnnotationMouseHandling?) {}
}
