import XCTest

@MainActor
final class AnnotationInteractionTests: XCTestCase {
    private let display = DisplayDescriptor(
        id: "d1",
        logicalBounds: Rect2D(x: -1000, y: 0, width: 1000, height: 600),
        pixelWidth: 2000,
        pixelHeight: 1200,
        backingScale: 2
    )

    private func session(_ coordinator: MeasurementCoordinator) {
        coordinator.startFreshSession(displays: [display], pointer: Point2D(x: -500, y: 300))
    }

    func testAddMoveRemove() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let annotation = MeasurementAnnotation(
            displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 10, y: 20), length: 100)
        )
        coordinator.addAnnotation(annotation)
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations.count, 1)

        let moved = AnnotationGeometry.horizontalMeasurement(start: Point2D(x: 50, y: 60), length: 100)
        coordinator.updateAnnotationGeometry(id: annotation.id, geometry: moved)
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry, moved)

        coordinator.removeAnnotation(id: annotation.id)
        XCTAssertTrue(coordinator.activeSession?.displays[0].annotations.isEmpty ?? false)
    }

    func testAnnotationForUnknownDisplayIsIgnored() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        coordinator.addAnnotation(
            MeasurementAnnotation(displayID: "other", geometry: .guideline(axis: .vertical, position: 5))
        )
        XCTAssertTrue(coordinator.activeSession?.displays[0].annotations.isEmpty ?? false)
    }

    func testMovePreservesLengthAndClamps() {
        let size = Size2D(width: 1000, height: 600)
        let geometry = AnnotationGeometry.horizontalMeasurement(start: Point2D(x: 100, y: 100), length: 200)
        XCTAssertEqual(
            AnnotationEditing.moved(geometry, dx: 5000, dy: -500, within: size),
            .horizontalMeasurement(start: Point2D(x: 800, y: 0), length: 200)
        )
        XCTAssertEqual(
            AnnotationEditing.moved(.guideline(axis: .horizontal, position: 10), dx: 99, dy: 20, within: size),
            .guideline(axis: .horizontal, position: 30)
        )
    }

    func testPinnedGeometry() {
        let bounds = Rect2D(x: 10, y: 20, width: 300, height: 100)
        XCTAssertEqual(
            AnnotationEditing.pinned(.horizontal, bounds: bounds, pointerLocal: Point2D(x: 50, y: 70)),
            .horizontalMeasurement(start: Point2D(x: 10, y: 70), length: 300)
        )
        XCTAssertEqual(
            AnnotationEditing.pinned(.vertical, bounds: bounds, pointerLocal: Point2D(x: 50, y: 70)),
            .verticalMeasurement(start: Point2D(x: 50, y: 20), length: 100)
        )
    }

    func testHitTesting() {
        let h = MeasurementAnnotation(
            displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 100, y: 100), length: 200)
        )
        let g = MeasurementAnnotation(displayID: "d1", geometry: .guideline(axis: .vertical, position: 500))
        let list = [h, g]
        XCTAssertEqual(AnnotationHitTester.hit(at: Point2D(x: 150, y: 102), in: list, labelFontSize: 14), .body(h.id))
        XCTAssertEqual(AnnotationHitTester.hit(at: Point2D(x: 503, y: 400), in: list, labelFontSize: 14), .body(g.id))
        XCTAssertNil(AnnotationHitTester.hit(at: Point2D(x: 400, y: 300), in: list, labelFontSize: 14))
        let label = AnnotationLayout.labelRect(for: h.geometry, fontSize: 14)!
        let center = Point2D(x: label.minX + label.size.width / 2, y: label.minY + label.size.height / 2)
        XCTAssertEqual(AnnotationHitTester.hit(at: center, in: list, labelFontSize: 14), .label(h.id))
    }

    func testPinCommandStoresLocalGeometryOnPointerDisplay() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let surface = StubSurface(displays: [display])
        let candidate = DetectionCandidate(
            bounds: Rect2D(x: 100, y: 200, width: 300, height: 150),
            source: .vision,
            confidence: 0.5,
            displayID: "d1"
        )
        let controller = AnnotationInteractionController(
            coordinator: coordinator,
            surface: surface,
            preferencesStore: PreferencesStore.shared,
            currentMeasurement: { candidate }
        )
        controller.handle(.pinHorizontal(at: Point2D(x: -800, y: 250)))
        controller.handle(.pinVertical(at: Point2D(x: -800, y: 250)))
        let geometries = coordinator.activeSession?.displays[0].annotations.map(\.geometry)
        XCTAssertEqual(
            geometries,
            [
                .horizontalMeasurement(start: Point2D(x: 100, y: 250), length: 300),
                .verticalMeasurement(start: Point2D(x: 200, y: 200), length: 150),
            ]
        )
    }
}

@MainActor
private final class StubSurface: AnnotationSurfacePresenting {
    let connectedDisplays: [DisplayDescriptor]
    init(displays: [DisplayDescriptor]) { connectedDisplays = displays }
    func presentAnnotations(_ groups: [DisplayAnnotations], preferences: AppPreferences) {}
    func setAnnotationHover(_ hit: AnnotationHit?, onDisplay displayID: String?) {}
    func setAnnotationMouseHandler(_ handler: AnnotationMouseHandling?) {}
}
