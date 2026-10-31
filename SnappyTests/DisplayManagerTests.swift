import AppKit
import XCTest

final class DisplayManagerTests: XCTestCase {
    func testAnnotationGroupsRemainAssociatedWithDisconnectedDisplays() {
        let connected = makeDisplay(id: "display-a", x: 0)
        let disconnected = makeDisplay(id: "display-b", x: -1200)
        let groups = [
            DisplayAnnotations(
                display: connected,
                annotations: [makeAnnotation(displayID: connected.id)]
            ),
            DisplayAnnotations(
                display: disconnected,
                annotations: [makeAnnotation(displayID: disconnected.id)]
            )
        ]
        var registry = DisplayAnnotationRegistry()

        registry.replaceGroups(groups)
        registry.reconcileConnectedDisplays([connected, disconnected])
        registry.reconcileConnectedDisplays([connected])

        XCTAssertEqual(registry.groupsByDisplayID[disconnected.id], groups[1])
        XCTAssertEqual(registry.unavailableGroups, [groups[1]])

        registry.reconcileConnectedDisplays([connected, disconnected])

        XCTAssertTrue(registry.unavailableGroups.isEmpty)
        XCTAssertEqual(registry.groupsByDisplayID[disconnected.id], groups[1])
    }

    func testAnnotationGroupsUseDisplayIdentityNotScreenOrder() {
        let first = makeDisplay(id: "display-a", x: -1000)
        let second = makeDisplay(id: "display-b", x: 0)
        var registry = DisplayAnnotationRegistry()
        registry.replaceGroups([
            DisplayAnnotations(display: first, annotations: [makeAnnotation(displayID: first.id)])
        ])

        registry.reconcileConnectedDisplays([second, first])

        XCTAssertEqual(registry.groupsByDisplayID[first.id]?.display, first)
        XCTAssertTrue(registry.unavailableGroups.isEmpty)
    }

    func testOverlayPanelIsTransparentNonactivatingAndClickThrough() async {
        await MainActor.run {
            let frame = NSRect(x: -1000, y: 0, width: 1000, height: 800)
            let panel = ScreenOverlayPanel(frame: frame)
            defer { panel.close() }

            XCTAssertTrue(panel.styleMask.contains(.borderless))
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertFalse(panel.isOpaque)
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertEqual(panel.backgroundColor, .clear)
            XCTAssertEqual(panel.level, .screenSaver)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertEqual(panel.frame, frame)
        }
    }

    @MainActor
    func testTemporaryOverlayAcceptsOnlyMatchingDisplayCandidates() {
        let view = TemporaryMeasurementOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 800)
        )
        let preferences = AppPreferences.default
        let candidate = DetectionCandidate(
            bounds: Rect2D(x: 20, y: 30, width: 200, height: 100),
            source: .accessibility,
            confidence: 0.9,
            displayID: "display-a"
        )

        view.update(
            .detected(candidate),
            pointer: Point2D(x: 50, y: 50),
            displayID: "display-a",
            preferences: preferences
        )

        XCTAssertEqual(view.content, .measurement(candidate, Point2D(x: 50, y: 50), preferences))
        XCTAssertEqual(
            view.dimensionLabels,
            TemporaryDimensionLabels(text: "200 × 100 pt")
        )

        view.update(
            .detected(candidate),
            pointer: Point2D(x: 50, y: 50),
            displayID: "display-b",
            preferences: preferences
        )

        XCTAssertNil(view.content)
        XCTAssertNil(view.dimensionLabels)
    }

    @MainActor
    func testTemporaryMeasurementControllerRejectsStaleDetectionAndClearsOnExit() async throws {
        let display = makeDisplay(id: "display-a", x: 0)
        let coordinator = MeasurementCoordinator()
        let firstPointer = Point2D(x: 40, y: 50)
        let latestPointer = Point2D(x: 90, y: 120)
        coordinator.startFreshSession(displays: [display], pointer: firstPointer)

        let staleCandidate = DetectionCandidate(
            bounds: Rect2D(x: 10, y: 10, width: 100, height: 60),
            source: .accessibility,
            confidence: 0.9,
            displayID: display.id
        )
        let latestCandidate = DetectionCandidate(
            bounds: Rect2D(x: 50, y: 60, width: 200, height: 90),
            source: .accessibility,
            confidence: 0.9,
            displayID: display.id
        )
        let detector = StubElementDetector(responses: [
            (0.2, .detected(staleCandidate)),
            (0, .detected(latestCandidate))
        ])
        let presenter = StubMeasurementPresenter()
        let environment = StubMeasurementDisplayProvider(display: display)
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = TemporaryMeasurementController(
            coordinator: coordinator,
            detector: detector,
            displayManager: presenter,
            displaySource: environment,
            preferencesStore: preferences,
            minimumDetectionInterval: 0
        )

        controller.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        coordinator.pointerMoved(to: latestPointer)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(presenter.presentedResults, [.detected(latestCandidate)])
        XCTAssertEqual(presenter.presentedPointers, [latestPointer])

        let clearCountBeforeExit = presenter.clearCount
        coordinator.stop()
        XCTAssertEqual(presenter.clearCount, clearCountBeforeExit + 1)
        controller.stop()
    }

    private func makeDisplay(id: String, x: Double) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            logicalBounds: Rect2D(x: x, y: 0, width: 1200, height: 800),
            pixelWidth: 2400,
            pixelHeight: 1600,
            backingScale: 2
        )
    }

    private func makeAnnotation(displayID: String) -> MeasurementAnnotation {
        MeasurementAnnotation(
            displayID: displayID,
            geometry: .horizontalMeasurement(
                start: Point2D(x: 10, y: 20),
                length: 100
            )
        )
    }
}

@MainActor
private final class StubElementDetector: ElementDetecting {
    private var responses: [(TimeInterval, ElementDetectionResult)]

    init(responses: [(TimeInterval, ElementDetectionResult)]) {
        self.responses = responses
    }

    func detect(
        at globalPointer: Point2D,
        displays: [DisplayDescriptor],
        primaryDisplayBounds: Rect2D,
        now: Date
    ) async -> ElementDetectionResult {
        guard !responses.isEmpty else { return .unavailable(.noConfidentBoundary) }
        let (delay, result) = responses.removeFirst()
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return result
    }
}

@MainActor
private final class StubMeasurementPresenter: TemporaryMeasurementPresenting {
    private(set) var presentedResults: [ElementDetectionResult] = []
    private(set) var presentedPointers: [Point2D] = []
    private(set) var clearCount = 0

    func showTemporaryMeasurement(
        _ result: ElementDetectionResult,
        at globalPointer: Point2D,
        preferences: AppPreferences
    ) {
        presentedResults.append(result)
        presentedPointers.append(globalPointer)
    }

    func clearTemporaryMeasurements() {
        clearCount += 1
    }
}

@MainActor
private final class StubMeasurementDisplayProvider: MeasurementDisplayProviding {
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
}

final class TemporaryLabelPlacementTests: XCTestCase {
    func testLabelPrefersBottomRightAndFlipsNearEdges() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 100, height: 20)
        let normal = TemporaryDimensionLabels.origin(pointer: NSPoint(x: 500, y: 400), labelSize: size, in: bounds)
        XCTAssertGreaterThan(normal.x, 500)
        XCTAssertLessThan(normal.y, 400)
        let right = TemporaryDimensionLabels.origin(pointer: NSPoint(x: 990, y: 400), labelSize: size, in: bounds)
        XCTAssertLessThan(right.x + size.width, 990)
        let bottom = TemporaryDimensionLabels.origin(pointer: NSPoint(x: 500, y: 5), labelSize: size, in: bounds)
        XCTAssertGreaterThan(bottom.y, 5)
    }
}
