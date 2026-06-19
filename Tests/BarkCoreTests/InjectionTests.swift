import XCTest
@testable import BarkCore

final class InjectionTests: XCTestCase {
    // MARK: Secure-field policy

    func testRefusesWhenSecureInputActive() {
        let d = SecureFieldPolicy.decide(secureInputEnabled: true, focusedElementRole: "AXTextField")
        XCTAssertEqual(d, .refuse(reason: "Secure input is active (a password field is focused)."))
    }

    func testRefusesSecureField() {
        let d = SecureFieldPolicy.decide(secureInputEnabled: false, focusedElementRole: "AXSecureTextField")
        if case .refuse = d { } else { XCTFail("expected refuse") }
    }

    func testAllowsSecureFieldWhenExplicitlyOptedIn() {
        let d = SecureFieldPolicy.decide(secureInputEnabled: false, focusedElementRole: "AXSecureTextField", allowIntoSecureField: true)
        XCTAssertEqual(d, .proceed)
    }

    func testProceedsForNormalField() {
        XCTAssertEqual(SecureFieldPolicy.decide(secureInputEnabled: false, focusedElementRole: "AXTextField"), .proceed)
        XCTAssertEqual(SecureFieldPolicy.decide(secureInputEnabled: false, focusedElementRole: nil), .proceed)
    }

    // MARK: Terminal detection

    func testTerminalDetection() {
        XCTAssertTrue(TerminalDetector.isTerminal("com.apple.Terminal"))
        XCTAssertTrue(TerminalDetector.isTerminal("com.googlecode.iterm2"))
        XCTAssertTrue(TerminalDetector.isTerminal("com.mitchellh.ghostty"))
        XCTAssertFalse(TerminalDetector.isTerminal("com.apple.TextEdit"))
        XCTAssertFalse(TerminalDetector.isTerminal(nil))
    }

    func testInjectionTargetIsTerminal() {
        let t = InjectionTarget(pid: 42, bundleID: "com.googlecode.iterm2")
        XCTAssertTrue(t.isTerminal)
    }

    // MARK: Focus guard

    func testFocusUnchanged() {
        let captured = InjectionTarget(pid: 7, bundleID: "com.apple.TextEdit")
        XCTAssertTrue(FocusGuard.targetUnchanged(captured: captured, current: InjectionTarget(pid: 7, bundleID: "com.apple.TextEdit")))
    }

    func testFocusChangedByPID() {
        let captured = InjectionTarget(pid: 7, bundleID: "com.apple.TextEdit")
        XCTAssertFalse(FocusGuard.targetUnchanged(captured: captured, current: InjectionTarget(pid: 9, bundleID: "com.apple.TextEdit")))
    }

    func testFocusChangedWhenNil() {
        let captured = InjectionTarget(pid: 7, bundleID: nil)
        XCTAssertFalse(FocusGuard.targetUnchanged(captured: captured, current: nil))
    }

    // MARK: Output routing (006)

    func testRoutingCopyOnlyWinsEverywhere() {
        XCTAssertEqual(InjectionRouter.strategy(routing: .copyOnly, isTerminal: false), .copyOnly)
        XCTAssertEqual(InjectionRouter.strategy(routing: .copyOnly, isTerminal: true), .copyOnly)
    }

    func testRoutingInsertUsesPasteForNormalApps() {
        XCTAssertEqual(InjectionRouter.strategy(routing: .insert, isTerminal: false), .paste)
    }

    func testRoutingInsertUsesKeystrokeForTerminals() {
        XCTAssertEqual(InjectionRouter.strategy(routing: .insert, isTerminal: true), .keystroke)
    }

    func testOutputRoutingCodableRoundTrip() throws {
        for routing in OutputRouting.allCases {
            let data = try JSONEncoder().encode(routing)
            XCTAssertEqual(try JSONDecoder().decode(OutputRouting.self, from: data), routing)
        }
    }
}
