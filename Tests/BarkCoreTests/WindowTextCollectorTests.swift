import XCTest
@testable import BarkCore

/// The window-text walk policy. These cases encode why the first version
/// captured almost nothing from real apps: a three-role allow-list and
/// value-only reads.
final class WindowTextCollectorTests: XCTestCase {
    private struct Node: AXTextNode {
        var role: String
        var subrole: String?
        var value: String?
        var title: String?
        var kids: [Node] = []
        var children: [any AXTextNode] { kids }

        init(_ role: String, value: String? = nil, title: String? = nil,
             subrole: String? = nil, kids: [Node] = []) {
            self.role = role
            self.value = value
            self.title = title
            self.subrole = subrole
            self.kids = kids
        }
    }

    func testCollectsFromWebAndElectronRolesNotJustTextFields() {
        // The regression that mattered: a Chromium/Electron tree exposes none
        // of AXStaticText/AXTextArea/AXTextField at the interesting nodes.
        let tree = Node("AXWindow", kids: [
            Node("AXWebArea", kids: [
                Node("AXHeading", value: "Deploy failed"),
                Node("AXGroup", kids: [
                    Node("AXLink", title: "Re-run job"),
                    Node("AXCell", value: "exit code 1"),
                    Node("AXUnknown", value: "stack trace line"),
                ]),
            ]),
        ])
        let result = WindowTextCollector.extract(from: tree)
        XCTAssertEqual(result.text, "Deploy failed\nRe-run job\nexit code 1\nstack trace line")
        XCTAssertFalse(result.truncated)
    }

    func testValuePreferredOverTitleAndNeverBoth() {
        let node = Node("AXTextField", value: "typed text", title: "Subject")
        XCTAssertEqual(WindowTextCollector.extract(from: node).text, "typed text")
        // Title is used when there is no value.
        let labelOnly = Node("AXButton", title: "Send")
        XCTAssertEqual(WindowTextCollector.extract(from: labelOnly).text, "Send")
    }

    func testChromeRolesArePrunedWithTheirSubtrees() {
        let tree = Node("AXWindow", kids: [
            Node("AXScrollBar", value: "should not appear", kids: [
                Node("AXStaticText", value: "nor should this"),
            ]),
            Node("AXStaticText", value: "real content"),
        ])
        XCTAssertEqual(WindowTextCollector.extract(from: tree).text, "real content")
    }

    func testSecureFieldsAreNeverReadByRoleOrSubrole() {
        let tree = Node("AXWindow", kids: [
            Node("AXSecureTextField", value: "hunter2"),
            Node("AXTextField", value: "also secret", subrole: "AXSecureTextField"),
            Node("AXStaticText", value: "visible"),
        ])
        let text = WindowTextCollector.extract(from: tree).text
        XCTAssertEqual(text, "visible")
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("also secret"))
    }

    func testSecureSubtreeIsPrunedNotJustTheNode() {
        let tree = Node("AXSecureTextField", value: "outer", kids: [
            Node("AXStaticText", value: "inner leak"),
        ])
        XCTAssertTrue(WindowTextCollector.extract(from: tree).isEmpty)
    }

    func testConsecutiveDuplicatesAreCollapsed() {
        // Web trees repeat a label across nested wrapper nodes.
        let tree = Node("AXWindow", kids: [
            Node("AXGroup", value: "Send", kids: [Node("AXButton", title: "Send")]),
            Node("AXStaticText", value: "Send"),   // non-adjacent repeat is kept
            Node("AXStaticText", value: "done"),
        ])
        XCTAssertEqual(WindowTextCollector.extract(from: tree).text, "Send\ndone")
    }

    func testNodeCapTruncatesAndReportsIt() {
        let many = (0..<50).map { Node("AXStaticText", value: "line \($0)") }
        let result = WindowTextCollector.extract(
            from: Node("AXWindow", kids: many),
            limits: .init(maxNodes: 5))
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.nodeCount, 5)
        XCTAssertFalse(result.text.contains("line 40"))
    }

    func testCharacterCapCountsSeparators() {
        let tree = Node("AXWindow", kids: [
            Node("AXStaticText", value: "aaaa"),   // 4
            Node("AXStaticText", value: "bbbb"),   // + 1 separator + 4 = 9
        ])
        let tight = WindowTextCollector.extract(from: tree, limits: .init(maxCharacters: 8))
        XCTAssertTrue(tight.truncated)
        XCTAssertEqual(tight.text, "aaaa")

        let exact = WindowTextCollector.extract(from: tree, limits: .init(maxCharacters: 9))
        XCTAssertFalse(exact.truncated)
        XCTAssertEqual(exact.text, "aaaa\nbbbb")
    }

    func testDepthCapStopsRunawayTrees() {
        func nest(_ depth: Int) -> Node {
            depth == 0
                ? Node("AXStaticText", value: "bottom")
                : Node("AXGroup", kids: [nest(depth - 1)])
        }
        let result = WindowTextCollector.extract(from: nest(10), limits: .init(maxDepth: 3))
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.text.contains("bottom"))
    }

    func testWhitespaceOnlyValuesAreNotCollected() {
        let tree = Node("AXWindow", kids: [
            Node("AXStaticText", value: "   \n  "),
            Node("AXStaticText", value: "  real  "),
        ])
        XCTAssertEqual(WindowTextCollector.extract(from: tree).text, "real")
    }

    func testEmptyTreeIsHonestlyEmpty() {
        // "Empty" must be distinguishable from "we didn't look" by the caller.
        let result = WindowTextCollector.extract(from: Node("AXWindow"))
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.nodeCount, 1)
    }
}
