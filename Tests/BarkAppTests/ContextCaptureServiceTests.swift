import XCTest
@testable import BarkCore
@testable import BarkEngines

/// Decision tree of the capture service (015 FR-002/003/004/017): secure-field
/// refusal before any read, AX first, OCR only when AX is thin AND authorized,
/// thin-but-nonempty AX still usable, honest empty error. Seams injected so
/// this runs headlessly (the real AX/OCR adapters are manual-QA territory).
final class ContextCaptureServiceTests: XCTestCase {
    private let target = InjectionTarget(pid: 77, bundleID: "com.example.app")

    final class FakeOCR: WindowOCRReading, @unchecked Sendable {
        let isAuthorized: Bool
        let text: String
        private(set) var callCount = 0
        init(authorized: Bool, text: String = "OCR TEXT FROM WINDOW " + String(repeating: "x", count: 100)) {
            self.isAuthorized = authorized
            self.text = text
        }
        func recognizeText(target: InjectionTarget) async throws -> String {
            callCount += 1
            return text
        }
    }

    private func context(windowText: String, label: String? = nil) -> CapturedContext {
        CapturedContext(source: .accessibility, appBundleID: "com.example.app", windowTitle: "w",
                        fieldLabel: label, fieldValue: nil, fieldPlaceholder: nil, fieldRole: nil,
                        windowText: windowText)
    }

    private func make(
        ax: CapturedContext?,
        ocr: FakeOCR? = nil,
        secureInput: Bool = false,
        focusedRole: String? = nil,
        trusted: Bool = true
    ) -> ContextCaptureService {
        ContextCaptureService(
            ocr: ocr,
            axReader: { _ in ax },
            secureInputActive: { _ in secureInput },
            focusedRole: { _ in focusedRole },
            axTrusted: { trusted },
            prepareTarget: { _ in false },
            webContentSettleDelay: .zero
        )
    }

    /// A canvas-drawn terminal produces plenty of AX characters — all of them
    /// the app's own chrome — which sails past any length threshold. Accepting
    /// it hands the model a session sidebar as if it were the terminal.
    func testChromeOnlyTerminalPrefersOCROverItsOwnFurniture() async throws {
        let cmux = InjectionTarget(pid: 1290, bundleID: "com.cmuxterm.app")
        XCTAssertTrue(cmux.isTerminal, "cmux must be a known terminal")

        let chromeOnly = CapturedContext(
            source: .accessibility, appBundleID: cmux.bundleID, windowTitle: "Voice Capture",
            fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: "AXTextArea",
            windowText: String(repeating: "session label ", count: 40),   // ~560 chars of chrome
            hasContentRoleText: false)
        XCTAssertFalse(chromeOnly.isThin, "precondition: long enough to pass the length check")
        XCTAssertTrue(chromeOnly.isChromeOnly)

        // With OCR available, the screenshot wins.
        let withOCR = ContextCaptureService(
            ocr: FakeOCR(authorized: true, text: "$ swift test\n526 tests passed"),
            axReader: { _ in chromeOnly },
            secureInputActive: { _ in false }, focusedRole: { _ in nil }, axTrusted: { true },
            prepareTarget: { _ in false }, webContentSettleDelay: .zero)
        let ocrResult = try await withOCR.capture(target: cmux)
        XCTAssertEqual(ocrResult.source, .ocr)
        XCTAssertTrue(ocrResult.windowText.contains("526 tests passed"))

        // Without OCR, refuse rather than pass furniture off as the screen —
        // "we read nothing" is recoverable; confidently wrong context is not.
        let withoutOCR = ContextCaptureService(
            ocr: nil,
            axReader: { _ in chromeOnly },
            secureInputActive: { _ in false }, focusedRole: { _ in nil }, axTrusted: { true },
            prepareTarget: { _ in false }, webContentSettleDelay: .zero)
        do {
            _ = try await withoutOCR.capture(target: cmux)
            XCTFail("expected an honest empty rather than chrome")
        } catch {
            XCTAssertEqual(error as? ContextCaptureError, .empty)
        }
    }

    func testTerminalThatDoesExposeItsScrollbackIsAccepted() async throws {
        // Terminal.app / iTerm expose the scrollback as content — no OCR needed.
        let cmux = InjectionTarget(pid: 1290, bundleID: "com.cmuxterm.app")
        let real = CapturedContext(
            source: .accessibility, appBundleID: cmux.bundleID, windowTitle: "zsh",
            fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: "AXTextArea",
            windowText: String(repeating: "build output line\n", count: 20),
            hasContentRoleText: true)
        let service = ContextCaptureService(
            ocr: FakeOCR(authorized: true, text: "should not be used"),
            axReader: { _ in real },
            secureInputActive: { _ in false }, focusedRole: { _ in nil }, axTrusted: { true },
            prepareTarget: { _ in false }, webContentSettleDelay: .zero)
        let result = try await service.capture(target: cmux)
        XCTAssertEqual(result.source, .accessibility)
    }

    func testChromeOnlyNonTerminalIsStillAccepted() async throws {
        // Only terminals get this treatment: a web page's headings and labels
        // ARE its content, and 015 must not regress.
        let browser = InjectionTarget(pid: 7, bundleID: "com.brave.Browser")
        XCTAssertFalse(browser.isTerminal)
        let chromeish = CapturedContext(
            source: .accessibility, appBundleID: browser.bundleID, windowTitle: "Docs",
            fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: nil,
            windowText: String(repeating: "heading text ", count: 40),
            hasContentRoleText: false)
        let service = ContextCaptureService(
            ocr: nil, axReader: { _ in chromeish },
            secureInputActive: { _ in false }, focusedRole: { _ in nil }, axTrusted: { true },
            prepareTarget: { _ in false }, webContentSettleDelay: .zero)
        let result = try await service.capture(target: browser)
        XCTAssertEqual(result.source, .accessibility)
    }

    /// Chromium/Electron apps withhold their tree until asked, and then need a
    /// moment to build it — so the opt-in must happen BEFORE the read, and the
    /// read must wait when the opt-in was this call's doing.
    func testWebContentOptInHappensBeforeTheReadAndOnlySettlesWhenNeeded() async throws {
        let order = OrderRecorder()
        let rich = context(windowText: String(repeating: "a", count: 200))

        let firstCapture = ContextCaptureService(
            ocr: nil,
            axReader: { _ in order.record("read"); return rich },
            secureInputActive: { _ in false },
            focusedRole: { _ in nil },
            axTrusted: { true },
            prepareTarget: { _ in order.record("prepare"); return true },   // we opted it in
            webContentSettleDelay: .milliseconds(30)
        )
        let started = Date()
        _ = try await firstCapture.capture(target: InjectionTarget(pid: 1, bundleID: "com.example.Electron"))
        XCTAssertEqual(order.events, ["prepare", "read"])
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.03)

        // Already opted in → no settle cost on later captures.
        let laterCapture = ContextCaptureService(
            ocr: nil,
            axReader: { _ in rich },
            secureInputActive: { _ in false },
            focusedRole: { _ in nil },
            axTrusted: { true },
            prepareTarget: { _ in false },                                  // already enabled
            webContentSettleDelay: .seconds(5)                              // would blow the test
        )
        _ = try await laterCapture.capture(target: InjectionTarget(pid: 1, bundleID: "com.example.Electron"))
    }

    final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var events: [String] { lock.lock(); defer { lock.unlock() }; return seen }
        func record(_ event: String) { lock.lock(); seen.append(event); lock.unlock() }
    }

    /// The secure-field pre-check must ask about the focused element **inside
    /// the capture target**, not whichever app happens to hold system focus.
    /// During a discussion session that is Bark's own overlay panel, so a
    /// system-wide check would answer about the wrong app and let a password
    /// field in the target go unrefused on recapture.
    func testSecureCheckIsScopedToTheCaptureTarget() async throws {
        let seen = TargetRecorder()
        let rich = context(windowText: String(repeating: "a", count: 200))
        let service = ContextCaptureService(
            ocr: nil,
            axReader: { _ in rich },
            secureInputActive: { _ in false },
            focusedRole: { target in
                seen.record(target)
                return target.pid == 4242 ? "AXSecureTextField" : "AXTextArea"
            },
            axTrusted: { true }
        )
        // The target IS the app with the secure field → refuse.
        do {
            _ = try await service.capture(target: InjectionTarget(pid: 4242, bundleID: "com.example.App"))
            XCTFail("expected refusal for the target's own secure field")
        } catch {
            XCTAssertEqual(error as? ContextCaptureError, .secureField)
        }
        XCTAssertEqual(seen.pids, [4242])

        // A different app is being captured → its own focus governs, so capture proceeds.
        _ = try await service.capture(target: InjectionTarget(pid: 77, bundleID: "com.example.Other"))
        XCTAssertEqual(seen.pids, [4242, 77])
    }

    final class TargetRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int32] = []
        var pids: [Int32] { lock.lock(); defer { lock.unlock() }; return seen }
        func record(_ target: InjectionTarget) {
            lock.lock(); seen.append(target.pid); lock.unlock()
        }
    }

    func testRichAXWinsWithoutTouchingOCR() async throws {
        let rich = context(windowText: String(repeating: "a", count: 200))
        let ocr = FakeOCR(authorized: true)
        let captured = try await make(ax: rich, ocr: ocr).capture(target: target)
        XCTAssertEqual(captured.source, .accessibility)
        XCTAssertEqual(ocr.callCount, 0)
    }

    func testThinAXFallsBackToOCRWhenAuthorized() async throws {
        let thin = context(windowText: "hi", label: "Address")
        let ocr = FakeOCR(authorized: true)
        let captured = try await make(ax: thin, ocr: ocr).capture(target: target)
        XCTAssertEqual(captured.source, .ocr)
        XCTAssertTrue(captured.windowText.contains("OCR TEXT FROM WINDOW"))
        XCTAssertEqual(captured.fieldLabel, "Address")   // AX field metadata is kept alongside OCR text
        XCTAssertEqual(ocr.callCount, 1)
    }

    func testThinAXWithoutOCRPermissionStillReturnsWhatItHas() async throws {
        let thin = context(windowText: "", label: "Address")   // a labeled field alone can be enough
        let ocr = FakeOCR(authorized: false)
        let captured = try await make(ax: thin, ocr: ocr).capture(target: target)
        XCTAssertEqual(captured.source, .accessibility)
        XCTAssertEqual(ocr.callCount, 0)                       // never captured without permission
    }

    func testEmptyAXAndNoOCRThrowsEmpty() async {
        do {
            _ = try await make(ax: context(windowText: "   ")).capture(target: target)
            XCTFail("expected empty")
        } catch {
            XCTAssertEqual(error as? ContextCaptureError, .empty)
        }
    }

    func testSecureInputRefusesBeforeAnyRead() async {
        let ocr = FakeOCR(authorized: true)
        do {
            _ = try await make(ax: context(windowText: "rich text here"), ocr: ocr, secureInput: true)
                .capture(target: target)
            XCTFail("expected secureField")
        } catch {
            XCTAssertEqual(error as? ContextCaptureError, .secureField)
            XCTAssertEqual(ocr.callCount, 0)
        }
    }

    func testSecureFocusedRoleRefuses() async {
        do {
            _ = try await make(ax: context(windowText: "rich"), focusedRole: "AXSecureTextField")
                .capture(target: target)
            XCTFail("expected secureField")
        } catch {
            XCTAssertEqual(error as? ContextCaptureError, .secureField)
        }
    }

    func testMissingAccessibilityPermissionThrows() async {
        do {
            _ = try await make(ax: context(windowText: "rich"), trusted: false).capture(target: target)
            XCTFail("expected accessibilityDenied")
        } catch {
            XCTAssertEqual(error as? ContextCaptureError, .accessibilityDenied)
        }
    }
}
