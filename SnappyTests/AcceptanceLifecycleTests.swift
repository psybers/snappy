import Combine
import XCTest

@testable import Snappy

@MainActor
final class AcceptanceLifecycleTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func display(_ id: String, x: Double) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            logicalBounds: Rect2D(x: x, y: 0, width: 1000, height: 600),
            pixelWidth: 2000,
            pixelHeight: 1200,
            backingScale: 2
        )
    }

    func testAllAnnotationKindsSurviveQuitAndRestoreAcrossTwoDisplays() {
        let a = display("a", x: 0)
        let b = display("b", x: -1000)
        let displays = [a, b]
        let make = { (coordinator: MeasurementCoordinator) in
            SessionPersistenceController(
                store: SessionStore(directory: self.dir),
                coordinator: coordinator,
                displays: { displays }
            )
        }

        let first = MeasurementCoordinator()
        let c1 = make(first)
        c1.start(displayChanges: Just(displays).eraseToAnyPublisher())
        first.startFreshSession(displays: displays, pointer: Point2D(x: 5, y: 5))
        let geometries: [(String, AnnotationGeometry)] = [
            ("a", .horizontalMeasurement(start: Point2D(x: 10, y: 20), length: 100)),
            ("a", .verticalMeasurement(start: Point2D(x: 10, y: 20), length: 50)),
            ("b", .rectangle(Rect2D(x: 30, y: 40, width: 60, height: 70))),
            ("b", .guideline(axis: .vertical, position: 300)),
        ]
        for (id, geometry) in geometries {
            first.addAnnotation(MeasurementAnnotation(displayID: id, geometry: geometry))
        }
        c1.flush()

        // Hotkey with existing annotations must not clear them.
        first.startFreshSession(displays: displays, pointer: Point2D(x: 5, y: 5))
        XCTAssertEqual(first.activeSession?.annotationCount, 4)

        // Relaunch: a new coordinator restores everything onto the right displays.
        let second = MeasurementCoordinator()
        let c2 = make(second)
        XCTAssertTrue(c2.restoreLastSession())
        let restored = second.activeSession?.displays ?? []
        XCTAssertEqual(restored.first { $0.display.id == "a" }?.annotations.count, 2)
        XCTAssertEqual(restored.first { $0.display.id == "b" }?.annotations.count, 2)

        // Deleting one annotation and clearing leaves the snapshot restorable.
        if let id = second.activeSession?.displays.first(where: { $0.display.id == "b" })?.annotations.first?.id {
            second.removeAnnotation(id: id)
        }
        XCTAssertEqual(second.activeSession?.annotationCount, 3)
        second.clearAnnotations()
        XCTAssertEqual(second.activeSession?.annotationCount, 0)
        XCTAssertTrue(c2.hasRestorableSession)
    }

    func testPermissionFailuresReportUnavailableNotGuessedBounds() async {
        struct Denied: ScreenRegionCapturing {
            func capture(region: Rect2D, on display: DisplayDescriptor) async throws -> CapturedDisplayRegion {
                throw ScreenCaptureError.permissionDenied
            }
        }
        struct NoAX: AccessibilityElementQuerying {
            var isTrusted: Bool { false }
            func element(at accessibilityPoint: Point2D) -> AccessibilityElementSnapshot? { nil }
        }
        let d = display("a", x: 0)
        let service = RectangleSelectionService(
            accessibilityClient: NoAX(), capturer: Denied(), contentDetector: ContentBoundsDetector())
        let analysis = await service.analyze(
            selection: Rect2D(x: 10, y: 10, width: 50, height: 50),
            displays: [d],
            primaryDisplayBounds: d.logicalBounds
        )
        // With both detectors failing, the dragged selection itself is used and flagged as unsourced.
        XCTAssertEqual(analysis?.bounds, Rect2D(x: 10, y: 10, width: 50, height: 50))
        XCTAssertNil(analysis?.source)
    }
}
