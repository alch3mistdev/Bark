import XCTest
@testable import BarkCore

final class DiscussionKeyDecoderTests: XCTestCase {
    func testMappings() {
        XCTAssertEqual(DiscussionKeyDecoder.decode(keyCode: 53), .cancel)   // Esc
        XCTAssertEqual(DiscussionKeyDecoder.decode(keyCode: 36), .confirm)  // Return
        XCTAssertEqual(DiscussionKeyDecoder.decode(keyCode: 2), .done)      // D
        XCTAssertEqual(DiscussionKeyDecoder.decode(keyCode: 15), .resume)   // R
        XCTAssertEqual(DiscussionKeyDecoder.decode(keyCode: 8), .copy)      // C
    }

    func testUnmappedKeysPassThrough() {
        // Digits/arrows belong to the suggestions overlay, not this one.
        for code: UInt16 in [18, 126, 125, 49, 0, 98] {
            XCTAssertNil(DiscussionKeyDecoder.decode(keyCode: code), "\(code)")
        }
    }
}
