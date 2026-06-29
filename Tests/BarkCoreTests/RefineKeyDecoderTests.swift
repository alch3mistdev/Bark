import XCTest
@testable import BarkCore

/// Pure left-option detection for hold-to-refine (012).
/// Mirrors the decode table in contracts/refine-key-decoder.md.
final class RefineKeyDecoderTests: XCTestCase {
    private let left = RefineKeyDecoder.leftOptionKeycode   // 58
    private let right: Int64 = 61

    func testLeftOptionDownWhileFnHeldStarts() {
        XCTAssertEqual(
            RefineKeyDecoder.decide(alternateOn: true, keycode: left, fnHeld: true, auxHeld: false),
            .refineStart)
    }

    func testLeftOptionUpEnds() {
        XCTAssertEqual(
            RefineKeyDecoder.decide(alternateOn: false, keycode: left, fnHeld: true, auxHeld: true),
            .refineEnd)
    }

    func testRightOptionIgnored() {
        XCTAssertNil(
            RefineKeyDecoder.decide(alternateOn: true, keycode: right, fnHeld: true, auxHeld: false))
    }

    func testNoActiveSessionIgnored() {
        XCTAssertNil(
            RefineKeyDecoder.decide(alternateOn: true, keycode: left, fnHeld: false, auxHeld: false))
    }

    func testNoDoubleFireWhenAlreadyOpen() {
        XCTAssertNil(
            RefineKeyDecoder.decide(alternateOn: true, keycode: left, fnHeld: true, auxHeld: true))
    }

    func testReleaseWithNothingOpenIgnored() {
        XCTAssertNil(
            RefineKeyDecoder.decide(alternateOn: false, keycode: left, fnHeld: true, auxHeld: false))
    }

    func testOtherKeyIgnored() {
        XCTAssertNil(
            RefineKeyDecoder.decide(alternateOn: true, keycode: 54, fnHeld: true, auxHeld: false))
    }
}
