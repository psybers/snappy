import AppKit
import XCTest

@testable import Snappy

/// Tests for `TemporaryMeasurementController.swift` — detection scheduling,
/// stale-result rejection, Shift crosshair mode, and tolerance-change
/// redetection.
@MainActor
final class TemporaryMeasurementControllerTests: XCTestCase {
    private func makeDisplay(id: String, x: Double) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            logicalBounds: Rect2D(x: x, y: 0, width: 1200, height: 800),
            pixelWidth: 2400,
            pixelHeight: 1600,
            backingScale: 2
        )
    }

    func testToleranceChangeRedetectsWithoutPointerMovement() async throws {
        let display = makeDisplay(id: "display-a", x: 0)
        let coordinator = MeasurementCoordinator()
        let pointer = Point2D(x: 50, y: 50)
        coordinator.startFreshSession(displays: [display], pointer: pointer)
        let detector = StubElementDetector(responses: [
            (0, .unavailable(.noConfidentBoundary)),
            (0, .unavailable(.noConfidentBoundary))
        ])
        let presenter = StubMeasurementPresenter()
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = TemporaryMeasurementController(
            coordinator: coordinator, detector: detector, displayManager: presenter,
            displaySource: StubMeasurementDisplayProvider(display: display),
            preferencesStore: preferences, minimumDetectionInterval: 0)
        controller.start()
        defer { controller.stop() }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(detector.callCount, 1)
        preferences.setEdgeToleranceLevel(.low)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(detector.callCount, 2)
        XCTAssertEqual(presenter.presentedPointers, [pointer, pointer])
    }

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

    func testShiftCrosshairUpdatesImmediatelyAndRejectsPendingDetection() async throws {
        let display = makeDisplay(id: "display-a", x: 0)
        let coordinator = MeasurementCoordinator()
        let pointer = Point2D(x: 40, y: 50)
        coordinator.startFreshSession(displays: [display], pointer: pointer)
        let detector = StubElementDetector(responses: [
            (0.1, .unavailable(.noConfidentBoundary)),
            (0, .unavailable(.noConfidentBoundary))
        ])
        let presenter = StubMeasurementPresenter()
        let controller = TemporaryMeasurementController(
            coordinator: coordinator, detector: detector, displayManager: presenter,
            displaySource: StubMeasurementDisplayProvider(display: display),
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            minimumDetectionInterval: 0
        )
        controller.start()
        defer { controller.stop() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(detector.callCount, 1)
        coordinator.updateShiftState(true)
        let moved = Point2D(x: 100, y: 150)
        coordinator.pointerMoved(to: moved)
        XCTAssertTrue(coordinator.mode.shiftHeld)
        XCTAssertEqual(presenter.crosshairPointers, [pointer, moved])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(detector.callCount, 1)
        XCTAssertTrue(presenter.presentedResults.isEmpty)

        coordinator.updateShiftState(false)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(detector.callCount, 2)
        XCTAssertEqual(presenter.presentedPointers, [moved])
    }

    func testShiftToggleRestoresMeasurementImmediatelyWithoutMouseMovement() async throws {
        let display = makeDisplay(id: "display-a", x: 0)
        let coordinator = MeasurementCoordinator()
        let pointer = Point2D(x: 40, y: 50)
        coordinator.startFreshSession(displays: [display], pointer: pointer)
        let candidate = DetectionCandidate(
            bounds: Rect2D(x: 10, y: 10, width: 100, height: 60),
            source: .accessibility, confidence: 0.9, displayID: display.id)
        let detector = StubElementDetector(responses: [(0, .detected(candidate))])
        let presenter = StubMeasurementPresenter()
        let controller = TemporaryMeasurementController(
            coordinator: coordinator, detector: detector, displayManager: presenter,
            displaySource: StubMeasurementDisplayProvider(display: display),
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            minimumDetectionInterval: 0
        )
        controller.start()
        defer { controller.stop() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.presentedResults, [.detected(candidate)])

        for _ in 0..<2 {
            let count = presenter.presentedResults.count
            coordinator.updateShiftState(true)
            XCTAssertEqual(presenter.crosshairPointers.last, pointer)
            coordinator.updateShiftState(false)
            // No await or mouse event: the cached measurement is presented synchronously.
            XCTAssertEqual(presenter.presentedResults.count, count + 1)
            XCTAssertEqual(presenter.presentedResults.last, .detected(candidate))
            XCTAssertEqual(controller.lastDetectedCandidate, candidate)
        }
        XCTAssertEqual(detector.callCount, 1)
    }
}
