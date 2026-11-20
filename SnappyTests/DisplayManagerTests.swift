import AppKit
import XCTest

/// Tests for `DisplayManager.swift` — `DisplayAnnotationRegistry`
/// association of annotation groups with displays, including disconnected
/// displays.
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
