import XCTest

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testIsNewerComparesDottedVersionsNumerically() {
        XCTAssertTrue(UpdateChecker.isNewer("0.4.2", than: "0.4.1"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertFalse(UpdateChecker.isNewer("0.4.1", than: "0.4.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.4.0", than: "0.4.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "0.10.0"))
    }

    func testIsNewerHandlesMissingComponentsAndSuffixes() {
        XCTAssertTrue(UpdateChecker.isNewer("0.4.1.1", than: "0.4.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.4", than: "0.4.1"))
        XCTAssertTrue(UpdateChecker.isNewer("0.5", than: "0.4.9"))
    }
}
