import XCTest
@testable import BarkCore

/// History-informed suggestions (015 FR-015): field-label + context keywords
/// score past outputs by term overlap, tie-broken by recency; top-3 snippets
/// clipped to 120 chars. Pure — records and `now` are injected.
final class HistoryRelevanceTests: XCTestCase {
    private func record(_ output: String, minutesAgo: Double, now: Date) -> HistoryRecord {
        HistoryRecord(createdAt: now.addingTimeInterval(-minutesAgo * 60),
                      transcript: "", output: output, modeID: "clean", appBundleID: nil)
    }

    func testKeywordsPreferLabelStripStopwordsAndCap() {
        let words = HistoryRelevance.keywords(
            fieldLabel: "Shipping Address",
            contextTail: "please enter the address for your order and the delivery notes"
        )
        XCTAssertEqual(words.first, "shipping")            // label tokens first
        XCTAssertTrue(words.contains("address"))
        XCTAssertFalse(words.contains("the"))              // stopword
        XCTAssertFalse(words.contains("for"))
        XCTAssertLessThanOrEqual(words.count, 6)
    }

    func testKeywordsDedupeAndDropShortTokens() {
        let words = HistoryRelevance.keywords(fieldLabel: "Address address", contextTail: "an ad hoc address")
        XCTAssertEqual(words.filter { $0 == "address" }.count, 1)
        XCTAssertFalse(words.contains("ad"))               // len < 3
    }

    func testSnippetsScoredByOverlapThenRecency() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            record("42 Foo Street, Nairobi — home address", minutesAgo: 60, now: now),   // 1 hit, older
            record("Meeting notes about the quarterly report", minutesAgo: 5, now: now), // 0 hits
            record("Ship to: 42 Foo Street. Address confirmed for shipping", minutesAgo: 10, now: now), // 2 hits
        ]
        let snippets = HistoryRelevance.snippets(
            from: records,
            keywords: ["shipping", "address"]
        )
        XCTAssertEqual(snippets.count, 2)                  // zero-hit record excluded
        XCTAssertTrue(snippets[0].contains("Ship to"))     // higher overlap wins
        XCTAssertTrue(snippets[1].contains("42 Foo Street, Nairobi"))
    }

    func testRecencyBreaksTies() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            record("address one", minutesAgo: 120, now: now),
            record("address two", minutesAgo: 1, now: now),
        ]
        let snippets = HistoryRelevance.snippets(from: records, keywords: ["address"])
        XCTAssertEqual(snippets, ["address two", "address one"])
    }

    func testTopThreeAndClippedTo120() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let long = "address " + String(repeating: "x", count: 200)
        let records = (0..<5).map { record("\(long) \($0)", minutesAgo: Double($0), now: now) }
        let snippets = HistoryRelevance.snippets(from: records, keywords: ["address"])
        XCTAssertEqual(snippets.count, 3)
        XCTAssertTrue(snippets.allSatisfy { $0.count <= 120 })
    }

    func testNoKeywordsOrNoMatchesYieldsEmpty() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [record("something unrelated", minutesAgo: 1, now: now)]
        XCTAssertEqual(HistoryRelevance.snippets(from: records, keywords: []), [])
        XCTAssertEqual(HistoryRelevance.snippets(from: records, keywords: ["address"]), [])
    }

    func testMatchingIsCaseInsensitive() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [record("MY ADDRESS IS HERE", minutesAgo: 1, now: now)]
        XCTAssertEqual(HistoryRelevance.snippets(from: records, keywords: ["address"]).count, 1)
    }
}
