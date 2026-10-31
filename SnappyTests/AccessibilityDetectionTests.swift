import XCTest

@MainActor
final class AccessibilityDetectionTests: XCTestCase {
    func testDeniedAccessibilityPermissionIsReportedExplicitly() {
        let detector = AccessibilityElementDetector(
            client: AccessibilityClientStub(isTrusted: false, element: nil)
        )

        XCTAssertEqual(
            detector.detect(
                at: Point2D(x: 150, y: 650),
                displays: [primaryDisplay],
                primaryDisplayBounds: primaryDisplay.logicalBounds
            ),
            .unavailable(.accessibilityPermissionDenied)
        )
    }

    func testMissingElementAndAttributesAreReportedAsUnavailable() {
        let missingElementDetector = AccessibilityElementDetector(
            client: AccessibilityClientStub(isTrusted: true, element: nil)
        )
        let missingAttributesDetector = AccessibilityElementDetector(
            client: AccessibilityClientStub(
                isTrusted: true,
                element: AccessibilityElementSnapshot(
                    position: Point2D(x: 100, y: 100),
                    size: nil,
                    role: "AXButton"
                )
            )
        )

        XCTAssertEqual(
            detect(missingElementDetector),
            .unavailable(.accessibilityElementUnavailable)
        )
        XCTAssertEqual(
            detect(missingAttributesDetector),
            .unavailable(.accessibilityElementUnavailable)
        )
    }

    func testInvalidGeometryAndPointerOutsideBoundsAreRejected() {
        let invalidGeometryDetector = AccessibilityElementDetector(
            client: AccessibilityClientStub(
                isTrusted: true,
                element: AccessibilityElementSnapshot(
                    position: Point2D(x: 100, y: 100),
                    size: Size2D(width: .infinity, height: 100),
                    role: "AXButton"
                )
            )
        )
        let pointerOutsideDetector = AccessibilityElementDetector(
            client: AccessibilityClientStub(
                isTrusted: true,
                element: AccessibilityElementSnapshot(
                    position: Point2D(x: 100, y: 100),
                    size: Size2D(width: 50, height: 50),
                    role: "AXButton"
                )
            )
        )

        XCTAssertEqual(
            detect(invalidGeometryDetector),
            .unavailable(.invalidAccessibilityBounds)
        )
        XCTAssertEqual(
            pointerOutsideDetector.detect(
                at: Point2D(x: 300, y: 300),
                displays: [primaryDisplay],
                primaryDisplayBounds: primaryDisplay.logicalBounds
            ),
            .unavailable(.noConfidentBoundary)
        )
    }

    func testAcceptsSpecificElementAndReturnsDisplayLocalBoundsAndRole() {
        let detector = AccessibilityElementDetector(
            client: AccessibilityClientStub(
                isTrusted: true,
                element: AccessibilityElementSnapshot(
                    position: Point2D(x: 100, y: 100),
                    size: Size2D(width: 200, height: 100),
                    role: "AXButton"
                )
            )
        )

        XCTAssertEqual(
            detect(detector),
            .detected(
                DetectionCandidate(
                    bounds: Rect2D(x: 100, y: 600, width: 200, height: 100),
                    source: .accessibility,
                    confidence: 0.9,
                    displayID: "cgdisplay-primary",
                    elementRole: "AXButton"
                )
            )
        )
    }

    func testHitTestOnSecondaryDisplayReturnsThatDisplaysLocalCoordinates() {
        let secondaryDisplay = DisplayDescriptor(
            id: "cgdisplay-secondary",
            logicalBounds: Rect2D(x: -500, y: 0, width: 500, height: 400),
            pixelWidth: 1000,
            pixelHeight: 800,
            backingScale: 2
        )
        let detector = AccessibilityElementDetector(
            client: AccessibilityClientStub(
                isTrusted: true,
                element: AccessibilityElementSnapshot(
                    position: Point2D(x: -480, y: 550),
                    size: Size2D(width: 100, height: 100),
                    role: "AXButton"
                )
            )
        )

        XCTAssertEqual(
            detector.detect(
                at: Point2D(x: -450, y: 200),
                displays: [primaryDisplay, secondaryDisplay],
                primaryDisplayBounds: primaryDisplay.logicalBounds
            ),
            .detected(
                DetectionCandidate(
                    bounds: Rect2D(x: 20, y: 150, width: 100, height: 100),
                    source: .accessibility,
                    confidence: 0.9,
                    displayID: "cgdisplay-secondary",
                    elementRole: "AXButton"
                )
            )
        )
    }

    func testRejectsWindowAndDisplaySizedFallbacks() {
        let windowDetector = AccessibilityElementDetector(
            client: AccessibilityClientStub(
                isTrusted: true,
                element: AccessibilityElementSnapshot(
                    position: Point2D(x: 0, y: 0),
                    size: Size2D(width: 1000, height: 800),
                    role: "AXWindow"
                )
            )
        )
        let oversizedDetector = AccessibilityElementDetector(
            client: AccessibilityClientStub(
                isTrusted: true,
                element: AccessibilityElementSnapshot(
                    position: Point2D(x: 25, y: 25),
                    size: Size2D(width: 950, height: 750),
                    role: "AXButton"
                )
            )
        )

        XCTAssertEqual(detect(windowDetector), .unavailable(.noConfidentBoundary))
        XCTAssertEqual(detect(oversizedDetector), .unavailable(.noConfidentBoundary))
    }

    func testHitTestReceivesConvertedAccessibilityPointerCoordinates() {
        let client = AccessibilityClientStub(
            isTrusted: true,
            element: AccessibilityElementSnapshot(
                position: Point2D(x: 100, y: 100),
                size: Size2D(width: 200, height: 100),
                role: "AXButton"
            )
        )
        let detector = AccessibilityElementDetector(client: client)

        _ = detect(detector)

        XCTAssertEqual(client.lastPoint, Point2D(x: 150, y: 150))
    }

    private var primaryDisplay: DisplayDescriptor {
        DisplayDescriptor(
            id: "cgdisplay-primary",
            logicalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 800),
            pixelWidth: 2000,
            pixelHeight: 1600,
            backingScale: 2
        )
    }

    private func detect(_ detector: AccessibilityElementDetector) -> ElementDetectionResult {
        detector.detect(
            at: Point2D(x: 150, y: 650),
            displays: [primaryDisplay],
            primaryDisplayBounds: primaryDisplay.logicalBounds
        )
    }
}

@MainActor
private final class AccessibilityClientStub: AccessibilityElementQuerying {
    let isTrusted: Bool
    let result: AccessibilityElementSnapshot?
    private(set) var lastPoint: Point2D?

    init(isTrusted: Bool, element: AccessibilityElementSnapshot?) {
        self.isTrusted = isTrusted
        result = element
    }

    func element(at accessibilityPoint: Point2D) -> AccessibilityElementSnapshot? {
        lastPoint = accessibilityPoint
        return result
    }
}
