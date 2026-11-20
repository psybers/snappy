import XCTest

/// Tests for `GlobalShortcutService.swift` pieces reachable without Carbon
/// registration (the hotkey itself requires a real window server session).
final class GlobalShortcutServiceTests: XCTestCase {
    func testCarbonKeyCodeMappingSupportsConfiguredLettersAndRejectsUnsupportedKey() {
        XCTAssertEqual(GlobalShortcutService.virtualKeyCode(for: "F"), 3)
        XCTAssertEqual(GlobalShortcutService.virtualKeyCode(for: "v"), 9)
        XCTAssertEqual(GlobalShortcutService.virtualKeyCode(for: "1"), 18)
        XCTAssertNil(GlobalShortcutService.virtualKeyCode(for: "SPACE"))
        XCTAssertNil(GlobalShortcutService.virtualKeyCode(for: "FF"))
    }
}
