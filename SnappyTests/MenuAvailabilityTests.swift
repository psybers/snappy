import XCTest

final class MenuAvailabilityTests: XCTestCase {
    func testSessionAndAnnotationActionsStartUnavailable() {
        let availability = MenuAvailability()

        XCTAssertFalse(availability.hasRestorableSession)
        XCTAssertFalse(availability.hasAnnotations)
    }

    func testMenuActionsCanBecomeAvailable() {
        let availability = MenuAvailability(
            hasRestorableSession: true,
            hasAnnotations: true
        )

        XCTAssertTrue(availability.hasRestorableSession)
        XCTAssertTrue(availability.hasAnnotations)
    }
}
