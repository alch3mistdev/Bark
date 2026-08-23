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
            secureInputActive: { secureInput },
            focusedRole: { focusedRole },
            axTrusted: { trusted }
        )
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
