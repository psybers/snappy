import AppKit
import XCTest

@testable import Snappy

/// Tests for `ScreenOverlayPanel.swift` — the transparent, nonactivating,
/// click-through overlay panel.
final class ScreenOverlayPanelTests: XCTestCase {
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
}
