import Combine
import XCTest

@MainActor
final class MeasurementCoordinatorTests: XCTestCase {
    func testStartingHotkeySessionAlwaysCreatesFreshEmptySession() {
        let coordinator = MeasurementCoordinator()
        let display = makeDisplay(id: "display-a")

        coordinator.startFreshSession(displays: [display], pointer: Point2D(x: 20, y: 30))
        let first = coordinator.activeSession
        coordinator.startFreshSession(displays: [display], pointer: Point2D(x: 40, y: 50))

        XCTAssertNotEqual(coordinator.activeSession?.id, first?.id)
        XCTAssertEqual(coordinator.activeSession?.displays.count, 1)
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations, [])
        XCTAssertEqual(coordinator.mode, .tracking(pointer: Point2D(x: 40, y: 50)))
        XCTAssertEqual(first?.displays[0].annotations, [])
    }

    func testFreshSessionIncludesOnlyValidConnectedDisplays() {
        let coordinator = MeasurementCoordinator()
        let valid = makeDisplay(id: "display-a")
        var invalid = makeDisplay(id: "")
        invalid.backingScale = .nan

        coordinator.startFreshSession(
            displays: [valid, invalid],
            pointer: Point2D(x: 0, y: 0)
        )

        XCTAssertEqual(coordinator.activeSession?.displays.map(\.display.id), ["display-a"])
    }

    func testPointerTrackingAndRectangleSelectionNormalizeDragDirection() {
        let coordinator = MeasurementCoordinator()
        coordinator.startFreshSession(displays: [], pointer: Point2D(x: 0, y: 0))
        var commands: [MeasurementCommand] = []
        let subscription = coordinator.commands.sink { commands.append($0) }
        defer { subscription.cancel() }

        coordinator.leftMouseDown(at: Point2D(x: 80, y: 70))
        coordinator.pointerMoved(to: Point2D(x: 20, y: 10))
        XCTAssertEqual(
            coordinator.mode,
            .selecting(start: Point2D(x: 80, y: 70), current: Point2D(x: 20, y: 10))
        )

        coordinator.leftMouseUp(at: Point2D(x: 20, y: 10))

        XCTAssertEqual(coordinator.mode, .tracking(pointer: Point2D(x: 20, y: 10)))
        XCTAssertEqual(
            commands,
            [.selectRectangle(Rect2D(x: 20, y: 10, width: 60, height: 60))]
        )
    }

    func testZeroSizeSelectionDoesNotEmitCommand() {
        let coordinator = MeasurementCoordinator()
        coordinator.startFreshSession(displays: [], pointer: Point2D(x: 10, y: 10))
        var commands: [MeasurementCommand] = []
        let subscription = coordinator.commands.sink { commands.append($0) }
        defer { subscription.cancel() }

        coordinator.leftMouseDown(at: Point2D(x: 10, y: 10))
        coordinator.leftMouseUp(at: Point2D(x: 10, y: 10))

        XCTAssertTrue(commands.isEmpty)
    }

    func testKeyboardCommandsRespectExactModifierChordAndEscapeStopsMode() {
        let coordinator = MeasurementCoordinator()
        coordinator.startFreshSession(displays: [], pointer: Point2D(x: 45, y: 60))
        var commands: [MeasurementCommand] = []
        let subscription = coordinator.commands.sink { commands.append($0) }
        defer { subscription.cancel() }

        coordinator.keyDown(key: "h", keyCode: 4, modifiers: [])
        coordinator.keyDown(key: "v", keyCode: 9, modifiers: [])
        coordinator.keyDown(key: "h", keyCode: 4, modifiers: [.shift])
        coordinator.keyDown(key: "v", keyCode: 9, modifiers: [.shift])
        coordinator.keyDown(key: "h", keyCode: 4, modifiers: [.command, .shift])

        XCTAssertEqual(
            commands,
            [
                .pinHorizontal(at: Point2D(x: 45, y: 60)),
                .pinVertical(at: Point2D(x: 45, y: 60)),
                .addHorizontalGuideline(y: 60),
                .addVerticalGuideline(x: 45)
            ]
        )

        coordinator.keyDown(key: "\u{1B}", keyCode: 53, modifiers: [])

        XCTAssertEqual(coordinator.mode, .inactive)
    }

    func testStopPreservesActiveSessionAndIgnoresInputUntilRestart() {
        let coordinator = MeasurementCoordinator()
        coordinator.startFreshSession(displays: [], pointer: Point2D(x: 5, y: 6))
        let session = coordinator.activeSession

        coordinator.stop()
        coordinator.pointerMoved(to: Point2D(x: 50, y: 60))
        coordinator.leftMouseDown(at: Point2D(x: 1, y: 1))

        XCTAssertEqual(coordinator.mode, .inactive)
        XCTAssertEqual(coordinator.activeSession, session)
    }

    func testActivationShiftIsIgnoredUntilReleasedThenNextPressEnablesCrosshair() {
        let coordinator = MeasurementCoordinator()
        let pointer = Point2D(x: 20, y: 30)
        coordinator.startFreshSession(
            displays: [], pointer: pointer, shiftHeldAtActivation: true)
        coordinator.updateShiftState(true)
        XCTAssertEqual(coordinator.mode, .tracking(pointer: pointer))

        let moved = Point2D(x: 40, y: 50)
        coordinator.pointerMoved(to: moved, shiftHeld: true)
        XCTAssertEqual(coordinator.mode, .tracking(pointer: moved))

        coordinator.updateShiftState(false)
        coordinator.updateShiftState(true)
        XCTAssertEqual(coordinator.mode, .tracking(pointer: moved, shiftHeld: true))
        coordinator.updateShiftState(false)
        XCTAssertEqual(coordinator.mode, .tracking(pointer: moved))
    }

    func testActivationShiftCanBeReleasedByMouseEventAndResetsOnRestart() {
        let coordinator = MeasurementCoordinator()
        let pointer = Point2D(x: 20, y: 30)
        coordinator.startFreshSession(
            displays: [], pointer: pointer, shiftHeldAtActivation: true)
        coordinator.pointerMoved(to: pointer, shiftHeld: false)
        coordinator.pointerMoved(to: pointer, shiftHeld: true)
        XCTAssertTrue(coordinator.mode.shiftHeld)

        coordinator.stop()
        coordinator.startFreshSession(
            displays: [], pointer: pointer, shiftHeldAtActivation: true)
        coordinator.updateShiftState(true)
        XCTAssertFalse(coordinator.mode.shiftHeld)

        coordinator.stop()
        coordinator.startFreshSession(displays: [], pointer: pointer)
        coordinator.updateShiftState(true)
        XCTAssertTrue(coordinator.mode.shiftHeld)
    }

    private func makeDisplay(id: String) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            logicalBounds: Rect2D(x: -100, y: 0, width: 100, height: 80),
            pixelWidth: 200,
            pixelHeight: 160,
            backingScale: 2
        )
    }
}
