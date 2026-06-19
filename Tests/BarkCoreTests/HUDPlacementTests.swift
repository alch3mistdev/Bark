import XCTest
import CoreGraphics
@testable import BarkCore

final class HUDPlacementTests: XCTestCase {
    private let panel = CGSize(width: 440, height: 132)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)   // visibleFrame (AppKit)

    func testBottomCenter() {
        let p = HUDPlacement.bottomCenter(panelSize: panel, visibleFrame: screen)
        XCTAssertEqual(p.x, screen.midX - panel.width / 2, accuracy: 0.001)
        XCTAssertEqual(p.y, screen.minY + 120, accuracy: 0.001)
    }

    func testUnderCaretDropsBelowCaretInAppKitCoords() {
        // Primary 900 tall. Caret near top of screen in AX (top-left) coords:
        // origin.y = 100, height 20 → caret bottom AX = 120 → AppKit bottom = 900-120 = 780.
        // Panel sits gap(8)+height(132) below → y = 780 - 8 - 132 = 640.
        let caret = CGRect(x: 300, y: 100, width: 2, height: 20)
        let p = HUDPlacement.underCaret(caretAX: caret, panelSize: panel,
                                        visibleFrame: screen, primaryHeight: 900)
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.y, 640, accuracy: 0.001)
        XCTAssertEqual(p!.x, 300 - 2, accuracy: 0.001)
    }

    func testUnderCaretClampsToScreen() {
        // Caret hard against the left edge and very low → origin would go off-screen;
        // result must stay within the visible frame.
        let caret = CGRect(x: -50, y: 890, width: 2, height: 18)
        let p = HUDPlacement.underCaret(caretAX: caret, panelSize: panel,
                                        visibleFrame: screen, primaryHeight: 900)!
        XCTAssertGreaterThanOrEqual(p.x, screen.minX)
        XCTAssertLessThanOrEqual(p.x + panel.width, screen.maxX)
        XCTAssertGreaterThanOrEqual(p.y, screen.minY)
        XCTAssertLessThanOrEqual(p.y + panel.height, screen.maxY)
    }

    func testUnderCaretRejectsDegenerateRect() {
        XCTAssertNil(HUDPlacement.underCaret(caretAX: CGRect(x: 0, y: 0, width: 2, height: 0),
                                             panelSize: panel, visibleFrame: screen, primaryHeight: 900))
        XCTAssertNil(HUDPlacement.underCaret(caretAX: CGRect(x: CGFloat.infinity, y: 10, width: 2, height: 20),
                                             panelSize: panel, visibleFrame: screen, primaryHeight: 900))
        XCTAssertNil(HUDPlacement.underCaret(caretAX: CGRect(x: 0, y: 0, width: 2, height: 5000),
                                             panelSize: panel, visibleFrame: screen, primaryHeight: 900))
    }

    func testClampNoOpWhenInside() {
        let inside = CGPoint(x: 200, y: 200)
        let p = HUDPlacement.clamp(inside, panelSize: panel, into: screen)
        XCTAssertEqual(p, inside)
    }
}
