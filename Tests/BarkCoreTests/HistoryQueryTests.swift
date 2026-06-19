import XCTest
@testable import BarkCore

final class HistoryQueryTests: XCTestCase {
    private func rec(_ transcript: String, _ output: String, mode: String = "clean", bundle: String? = nil) -> HistoryRecord {
        HistoryRecord(transcript: transcript, output: output, modeID: mode, appBundleID: bundle)
    }

    private lazy var records: [HistoryRecord] = [
        rec("send the email now", "Send the email now.", mode: "email", bundle: "com.apple.mail"),
        rec("git status", "git status", mode: "raw", bundle: "com.apple.Terminal"),
        rec("hello résumé", "Hello résumé.", mode: "clean", bundle: "com.apple.TextEdit"),
    ]

    func testSubstringMatchesTranscriptOrOutput() {
        XCTAssertEqual(HistoryQuery.filter(records, matching: "git").map(\.output), ["git status"])
        // matches output even when transcript differs in case
        XCTAssertEqual(HistoryQuery.filter(records, matching: "email").count, 1)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(HistoryQuery.filter(records, matching: "GIT").count, 1)
        XCTAssertEqual(HistoryQuery.filter(records, matching: "EMAIL").count, 1)
    }

    func testDiacriticInsensitive() {
        XCTAssertEqual(HistoryQuery.filter(records, matching: "resume").count, 1)  // matches "résumé"
        XCTAssertEqual(HistoryQuery.filter(records, matching: "RÉSUMÉ").count, 1)
    }

    func testEmptyQueryMatchesAll() {
        XCTAssertEqual(HistoryQuery.filter(records, matching: "").count, 3)
        XCTAssertEqual(HistoryQuery.filter(records, matching: "   ").count, 3)  // whitespace trimmed
    }

    func testNoMatch() {
        XCTAssertTrue(HistoryQuery.filter(records, matching: "zzzznotfound").isEmpty)
    }

    func testModeFacet() {
        let r = HistoryQuery.filter(records, matching: "", modeID: "email")
        XCTAssertEqual(r.map(\.output), ["Send the email now."])
    }

    func testBundleFacet() {
        let r = HistoryQuery.filter(records, matching: "", bundleID: "com.apple.Terminal")
        XCTAssertEqual(r.map(\.output), ["git status"])
    }

    func testFacetPlusTextNarrows() {
        // text "the" appears in the email record; restrict to a different app → empty.
        XCTAssertTrue(HistoryQuery.filter(records, matching: "the", bundleID: "com.apple.Terminal").isEmpty)
        XCTAssertEqual(HistoryQuery.filter(records, matching: "the", bundleID: "com.apple.mail").count, 1)
    }
}
