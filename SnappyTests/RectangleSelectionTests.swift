import CoreGraphics
import XCTest

@testable import Snappy

/// Tests for `RectangleSelection.swift`: `SelectionGeometry`,
/// `ContentBoundsDetector`, `RectangleSelectionService`, and
/// `RectangleSelectionController`.
@MainActor
final class RectangleSelectionTests: XCTestCase {
    // MARK: - SelectionGeometry / ContentBoundsDetector

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

    func testContentBoundsFindsSquare() throws {
        let captured = CapturedDisplayRegion(
            image: try TestImages.filledRectImage(width: 100, height: 100, rect: (20, 30, 40, 10)),
            displayID: "d", displayLocalBounds: Rect2D(x: 100, y: 200, width: 100, height: 100))
        let bounds = ContentBoundsDetector().bounds(in: captured)
        XCTAssertEqual(bounds, Rect2D(x: 120, y: 230, width: 40, height: 10))
    }

    func testContentBoundsScale2() throws {
        let captured = CapturedDisplayRegion(
            image: try TestImages.filledRectImage(width: 100, height: 100, rect: (20, 30, 40, 10)),
            displayID: "d", displayLocalBounds: Rect2D(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(
            ContentBoundsDetector().bounds(in: captured), Rect2D(x: 10, y: 15, width: 20, height: 5))
    }

    func testContentBoundsEmpty() throws {
        let captured = CapturedDisplayRegion(
            image: try TestImages.filledRectImage(width: 40, height: 40, rect: nil),
            displayID: "d", displayLocalBounds: Rect2D(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNil(ContentBoundsDetector().bounds(in: captured))
    }

    // MARK: - Rectangle label / hit-testing helpers

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

    // MARK: - RectangleSelectionService

    private let serviceDisplay = makeTestDisplay(id: "d1")

    private func makeService(
        axTrusted: Bool = true,
        axElement: AccessibilityElementSnapshot? = nil,
        capture result: Result<CapturedDisplayRegion, Error>? = nil
    ) -> (RectangleSelectionService, StubRegionCapturer) {
        let ax = StubAccessibilityClient(isTrusted: axTrusted, element: axElement)
        let capturer = StubRegionCapturer(
            result: result ?? .failure(ScreenCaptureError.displayUnavailable))
        return (
            RectangleSelectionService(
                accessibilityClient: ax,
                capturer: capturer,
                contentDetector: ContentBoundsDetector()
            ),
            capturer
        )
    }

    /// An AX element covering AppKit-global rect (120, 120, 100, 50) on a
    /// display whose primary bounds are (0, 0, 1000, 600): the AX-space
    /// origin is top-left, so the snapshot's y is 600 - 170 = 430.
    private func axSnapshot() -> AccessibilityElementSnapshot {
        AccessibilityElementSnapshot(
            position: Point2D(x: 120, y: 430),
            size: Size2D(width: 100, height: 50),
            role: "AXButton"
        )
    }

    func testServicePrefersAccessibilityElements() async {
        let (service, _) = makeService(axElement: axSnapshot())
        let analysis = await service.analyze(
            selection: Rect2D(x: 100, y: 100, width: 200, height: 100),
            displays: [serviceDisplay],
            primaryDisplayBounds: serviceDisplay.logicalBounds
        )
        XCTAssertEqual(analysis?.displayID, "d1")
        XCTAssertEqual(analysis?.source, .accessibility)
        XCTAssertEqual(analysis?.bounds, Rect2D(x: 120, y: 120, width: 100, height: 50))
    }

    func testServiceFallsBackToVisionContentBounds() async throws {
        let captured = CapturedDisplayRegion(
            image: try TestImages.filledRectImage(width: 100, height: 100, rect: (20, 30, 40, 10)),
            displayID: "d1",
            displayLocalBounds: Rect2D(x: 100, y: 200, width: 100, height: 100)
        )
        // AX trusted but hit-testing finds nothing, so capture is used.
        let (service, capturer) = makeService(capture: .success(captured))
        let analysis = await service.analyze(
            selection: Rect2D(x: 100, y: 200, width: 100, height: 100),
            displays: [serviceDisplay],
            primaryDisplayBounds: serviceDisplay.logicalBounds
        )
        XCTAssertEqual(capturer.requestedDisplays, ["d1"])
        XCTAssertEqual(analysis?.source, .vision)
        XCTAssertEqual(analysis?.bounds, Rect2D(x: 120, y: 230, width: 40, height: 10))
    }

    func testServiceFallsBackToRawSelectionWhenCaptureFails() async {
        let (service, _) = makeService(capture: .failure(ScreenCaptureError.permissionDenied))
        let selection = Rect2D(x: 100, y: 200, width: 100, height: 100)
        let analysis = await service.analyze(
            selection: selection,
            displays: [serviceDisplay],
            primaryDisplayBounds: serviceDisplay.logicalBounds
        )
        XCTAssertNil(analysis?.source)
        XCTAssertEqual(analysis?.bounds, selection)
    }

    func testServiceAnalyzesDisplayContainingSelectionCenter() async {
        let a = serviceDisplay
        let b = makeTestDisplay(
            id: "d2", x: 2000, width: 500, height: 400,
            pixelWidth: 1000, pixelHeight: 800)
        let (service, _) = makeService(capture: .failure(ScreenCaptureError.permissionDenied))
        let analysis = await service.analyze(
            selection: Rect2D(x: 2050, y: 100, width: 200, height: 100),
            displays: [a, b],
            primaryDisplayBounds: a.logicalBounds
        )
        XCTAssertEqual(analysis?.displayID, "d2")
        XCTAssertEqual(analysis?.bounds, Rect2D(x: 50, y: 100, width: 200, height: 100))
    }

    func testServiceUsesIntersectingDisplayWhenCenterIsOutsideAll() async {
        let a = serviceDisplay
        let b = makeTestDisplay(
            id: "d2", x: 2000, width: 500, height: 400,
            pixelWidth: 1000, pixelHeight: 800)
        let (service, _) = makeService(capture: .failure(ScreenCaptureError.permissionDenied))
        // Center (1800, 200) is in the gap; the selection clips into d2.
        let analysis = await service.analyze(
            selection: Rect2D(x: 1500, y: 100, width: 600, height: 200),
            displays: [a, b],
            primaryDisplayBounds: a.logicalBounds
        )
        XCTAssertEqual(analysis?.displayID, "d2")
        XCTAssertEqual(analysis?.bounds, Rect2D(x: 0, y: 100, width: 100, height: 200))
    }

    func testServiceReturnsNilWhenSelectionMissesEveryDisplay() async {
        let b = makeTestDisplay(
            id: "d2", x: 2000, width: 500, height: 400,
            pixelWidth: 1000, pixelHeight: 800)
        let (service, capturer) = makeService(capture: .failure(ScreenCaptureError.permissionDenied))
        let analysis = await service.analyze(
            selection: Rect2D(x: 1200, y: 100, width: 100, height: 100),
            displays: [serviceDisplay, b],
            primaryDisplayBounds: serviceDisplay.logicalBounds
        )
        XCTAssertNil(analysis)
        XCTAssertTrue(capturer.requestedDisplays.isEmpty)
    }

    // MARK: - RectangleSelectionController

    func testSelectionRectNormalisesDrag() {
        let r = RectangleSelectionController.rect(from: Point2D(x: 50, y: 40), to: Point2D(x: 10, y: 90))
        XCTAssertEqual(r, Rect2D(x: 10, y: 40, width: 40, height: 50))
    }

    @MainActor
    func testControllerRejectsSelectionsBelowMinimumSize() async throws {
        let coordinator = MeasurementCoordinator()
        coordinator.startFreshSession(displays: [serviceDisplay], pointer: Point2D(x: 10, y: 10))
        let analyzer = StubSelectionAnalyzer()
        let controller = RectangleSelectionController(
            coordinator: coordinator,
            surface: StubSelectionSurface(
                displays: [serviceDisplay],
                primary: serviceDisplay.logicalBounds),
            analyzer: analyzer
        )
        controller.start()
        defer { controller.stop() }
        coordinator.commands.send(.selectRectangle(Rect2D(x: 0, y: 0, width: 3, height: 3)))
        coordinator.commands.send(.selectRectangle(Rect2D(x: 0, y: 0, width: 4, height: 2)))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(analyzer.calls, 0)
    }

    @MainActor
    func testControllerAddsPersistentRectangleFromAnalysis() async throws {
        let coordinator = MeasurementCoordinator()
        coordinator.startFreshSession(displays: [serviceDisplay], pointer: Point2D(x: 10, y: 10))
        let analyzer = StubSelectionAnalyzer()
        analyzer.results = [
            RectangleAnalysis(
                displayID: "d1",
                bounds: Rect2D(x: 10, y: 20, width: 30, height: 40),
                source: .vision
            )
        ]
        let controller = RectangleSelectionController(
            coordinator: coordinator,
            surface: StubSelectionSurface(
                displays: [serviceDisplay],
                primary: serviceDisplay.logicalBounds),
            analyzer: analyzer
        )
        controller.start()
        defer { controller.stop() }
        coordinator.commands.send(.selectRectangle(Rect2D(x: 0, y: 0, width: 100, height: 100)))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(analyzer.calls, 1)
        XCTAssertEqual(
            coordinator.activeSession?.displays[0].annotations.map(\.geometry),
            [.rectangle(Rect2D(x: 10, y: 20, width: 30, height: 40))]
        )
    }

    @MainActor
    func testControllerDiscardsAnalysisWhenModeExitsMidFlight() async throws {
        let coordinator = MeasurementCoordinator()
        coordinator.startFreshSession(displays: [serviceDisplay], pointer: Point2D(x: 10, y: 10))
        let analyzer = StubSelectionAnalyzer()
        analyzer.suspend = true
        let controller = RectangleSelectionController(
            coordinator: coordinator,
            surface: StubSelectionSurface(
                displays: [serviceDisplay],
                primary: serviceDisplay.logicalBounds),
            analyzer: analyzer
        )
        controller.start()
        defer { controller.stop() }
        coordinator.commands.send(.selectRectangle(Rect2D(x: 0, y: 0, width: 100, height: 100)))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(analyzer.calls, 1)
        coordinator.stop()
        analyzer.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 0)
    }

    @MainActor
    func testControllerDrivesSelectionSurfaceWithMode() {
        let coordinator = MeasurementCoordinator()
        let surface = StubSelectionSurface(
            displays: [serviceDisplay],
            primary: serviceDisplay.logicalBounds)
        let controller = RectangleSelectionController(
            coordinator: coordinator,
            surface: surface,
            analyzer: StubSelectionAnalyzer()
        )
        controller.start()
        defer { controller.stop() }

        coordinator.startFreshSession(displays: [serviceDisplay], pointer: Point2D(x: 10, y: 10))
        XCTAssertEqual(surface.captures.last, true)
        XCTAssertNil(surface.selectionRects.last ?? nil)

        coordinator.leftMouseDown(at: Point2D(x: 100, y: 100))
        XCTAssertEqual(
            surface.selectionRects.last ?? nil,
            Rect2D(x: 100, y: 100, width: 0, height: 0))

        coordinator.pointerMoved(to: Point2D(x: 300, y: 250))
        XCTAssertEqual(
            surface.selectionRects.last ?? nil,
            Rect2D(x: 100, y: 100, width: 200, height: 150))

        coordinator.leftMouseUp(at: Point2D(x: 300, y: 250))
        // The drag rect was shown during the gesture, then cleared on release.
        XCTAssertTrue(surface.selectionRects.contains(Rect2D(x: 100, y: 100, width: 200, height: 150)))
        XCTAssertNil(surface.selectionRects.last ?? nil)

        coordinator.stop()
        XCTAssertEqual(surface.captures.last, false)
    }
}

// MARK: - Test doubles

@MainActor
private final class StubSelectionSurface: SelectionSurfacePresenting {
    let connectedDisplays: [DisplayDescriptor]
    let primaryDisplayBounds: Rect2D?
    private(set) var selectionRects: [Rect2D?] = []
    private(set) var captures: [Bool] = []

    init(displays: [DisplayDescriptor], primary: Rect2D?) {
        connectedDisplays = displays
        primaryDisplayBounds = primary
    }

    func setSelectionRect(_ globalRect: Rect2D?) {
        selectionRects.append(globalRect)
    }

    func setCapturesMouse(_ captures: Bool) {
        self.captures.append(captures)
    }
}

@MainActor
private final class StubSelectionAnalyzer: RectangleSelectionAnalyzing {
    var results: [RectangleAnalysis?] = []
    private(set) var calls = 0
    var suspend = false
    private var continuation: CheckedContinuation<Void, Never>?

    func analyze(
        selection: Rect2D,
        displays: [DisplayDescriptor],
        primaryDisplayBounds: Rect2D
    ) async -> RectangleAnalysis? {
        calls += 1
        if suspend {
            await withCheckedContinuation { continuation = $0 }
        }
        return results.isEmpty ? nil : results.removeFirst()
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
