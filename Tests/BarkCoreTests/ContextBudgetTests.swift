import XCTest
@testable import BarkCore

/// Context clipping + thinness (015 FR-006): terminal-like targets keep the
/// TAIL (the agent's question is at the bottom of scrollback); forms keep the
/// HEAD. Budget is a constant, not a setting.
final class ContextBudgetTests: XCTestCase {
    func testStrategyByTargetKind() {
        XCTAssertEqual(ContextBudget.strategy(isTerminal: true), .tail)
        XCTAssertEqual(ContextBudget.strategy(isTerminal: false), .head)
    }

    func testClipTailKeepsMostRecentText() {
        let text = String(repeating: "a", count: 100) + "THE-END"
        let clipped = ContextBudget.clip(text, strategy: .tail, maxChars: 50)
        XCTAssertEqual(clipped.count, 50)
        XCTAssertTrue(clipped.hasSuffix("THE-END"))
    }

    func testClipHeadKeepsOpeningText() {
        let text = "THE-START" + String(repeating: "z", count: 100)
        let clipped = ContextBudget.clip(text, strategy: .head, maxChars: 50)
        XCTAssertEqual(clipped.count, 50)
        XCTAssertTrue(clipped.hasPrefix("THE-START"))
    }

    func testClipNoOpUnderBudget() {
        XCTAssertEqual(ContextBudget.clip("short", strategy: .tail, maxChars: 50), "short")
        XCTAssertEqual(ContextBudget.clip("short", strategy: .head, maxChars: 50), "short")
    }

    func testDefaultBudgetIs4000() {
        XCTAssertEqual(ContextBudget.maxChars, 4000)
        let long = String(repeating: "x", count: 5000)
        XCTAssertEqual(ContextBudget.clip(long, strategy: .tail).count, 4000)
    }

    func testThinnessThreshold() {
        // Useful text = windowText + field value/label/placeholder, whitespace-collapsed.
        let thin = CapturedContext(
            source: .accessibility, appBundleID: nil, windowTitle: nil,
            fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: nil,
            windowText: String(repeating: "a", count: ContextBudget.thinThreshold - 1)
        )
        XCTAssertTrue(thin.isThin)

        let rich = CapturedContext(
            source: .accessibility, appBundleID: nil, windowTitle: nil,
            fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: nil,
            windowText: String(repeating: "a", count: ContextBudget.thinThreshold)
        )
        XCTAssertFalse(rich.isThin)
    }

    func testFieldMetadataCountsTowardThinness() {
        // A short window text but a labeled field with a placeholder can still be useful.
        let labeled = CapturedContext(
            source: .accessibility, appBundleID: nil, windowTitle: nil,
            fieldLabel: String(repeating: "l", count: 40),
            fieldValue: String(repeating: "v", count: 40),
            fieldPlaceholder: nil, fieldRole: "AXTextField",
            windowText: ""
        )
        XCTAssertFalse(labeled.isThin)
    }

    func testWhitespaceOnlyTextIsThin() {
        let blank = CapturedContext(
            source: .ocr, appBundleID: nil, windowTitle: nil,
            fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: nil,
            windowText: String(repeating: " \n\t", count: 100)
        )
        XCTAssertTrue(blank.isThin)
    }
}
