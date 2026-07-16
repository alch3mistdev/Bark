import XCTest
@testable import BarkCore

/// Keycode → overlay event table (015 FR-009). Twin of RefineKeyDecoderTests:
/// OS keycodes live in one unit-tested place so the overlay stays thin.
final class SuggestionKeyDecoderTests: XCTestCase {
    func testNumberKeysChooseZeroBasedIndex() {
        XCTAssertEqual(SuggestionKeyDecoder.decode(keyCode: 18), .choose(0))   // 1
        XCTAssertEqual(SuggestionKeyDecoder.decode(keyCode: 19), .choose(1))   // 2
        XCTAssertEqual(SuggestionKeyDecoder.decode(keyCode: 20), .choose(2))   // 3
        XCTAssertEqual(SuggestionKeyDecoder.decode(keyCode: 21), .choose(3))   // 4
    }

    func testArrows() {
        XCTAssertEqual(SuggestionKeyDecoder.decode(keyCode: 126), .moveUp)
        XCTAssertEqual(SuggestionKeyDecoder.decode(keyCode: 125), .moveDown)
    }

    func testReturnAndKeypadEnterAccept() {
        XCTAssertEqual(SuggestionKeyDecoder.decode(keyCode: 36), .accept)
        XCTAssertEqual(SuggestionKeyDecoder.decode(keyCode: 76), .accept)
    }

    func testEscapeDismisses() {
        XCTAssertEqual(SuggestionKeyDecoder.decode(keyCode: 53), .dismiss)
    }

    func testOKeyIsOther() {
        XCTAssertEqual(SuggestionKeyDecoder.decode(keyCode: 31), .other)
    }

    func testUnknownKeysPassThrough() {
        XCTAssertNil(SuggestionKeyDecoder.decode(keyCode: 0))     // 'a'
        XCTAssertNil(SuggestionKeyDecoder.decode(keyCode: 49))    // space
        XCTAssertNil(SuggestionKeyDecoder.decode(keyCode: 96))    // F5
        XCTAssertNil(SuggestionKeyDecoder.decode(keyCode: 123))   // left arrow
        XCTAssertNil(SuggestionKeyDecoder.decode(keyCode: 124))   // right arrow
    }
}
