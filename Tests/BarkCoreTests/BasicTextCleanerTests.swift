import XCTest
@testable import BarkCore

final class BasicTextCleanerTests: XCTestCase {
    func testRawModeIsLossless() {
        let input = "um so I think uh it WORKS"
        XCTAssertEqual(BasicTextCleaner.process(input, mode: .raw), input)
    }

    func testRemovesFillers() {
        let out = BasicTextCleaner.process("um so I think uh it works", mode: .clean)
        XCTAssertEqual(out, "So I think it works")
    }

    func testRemovesMultiWordFillers() {
        let out = BasicTextCleaner.process("this is you know really good", mode: .clean)
        XCTAssertEqual(out, "This is really good")
    }

    func testSpokenPunctuation() {
        let out = BasicTextCleaner.process("hello comma world period new line bye", mode: .clean)
        XCTAssertEqual(out, "Hello, world.\nBye")
    }

    func testStandaloneIIsCapitalized() {
        let out = BasicTextCleaner.process("i think i am happy", mode: .clean)
        XCTAssertEqual(out, "I think I am happy")
    }

    func testContractionIIsCapitalized() {
        let out = BasicTextCleaner.process("i'm sure i'll be fine", mode: .clean)
        XCTAssertEqual(out, "I'm sure I'll be fine")
    }

    func testFixesSpacingBeforePunctuation() {
        let out = BasicTextCleaner.process("hello , world .", mode: .clean)
        XCTAssertEqual(out, "Hello, world.")
    }

    func testCollapsesWhitespace() {
        let out = BasicTextCleaner.process("too    many     spaces", mode: .clean)
        XCTAssertEqual(out, "Too many spaces")
    }

    func testCodeModeKeepsCasing() {
        // Code mode disables smart-capitalize so identifiers survive.
        let out = BasicTextCleaner.process("fix the parseURL helper", mode: .code)
        XCTAssertEqual(out, "fix the parseURL helper")
    }

    func testFillerNotRemovedInsideWord() {
        // "summary" contains "um" but must not be touched.
        let out = BasicTextCleaner.process("summary of umbrella", mode: .clean)
        XCTAssertEqual(out, "Summary of umbrella")
    }
}
