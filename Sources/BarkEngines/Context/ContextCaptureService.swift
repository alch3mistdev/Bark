import AppKit
import ApplicationServices
import BarkCore

/// Reads text from the frontmost window for OCR fallback (015 FR-003).
/// Concrete impl: `WindowOCRReader` (ScreenCaptureKit + Vision). Nil/absent →
/// the service degrades to AX-only.
public protocol WindowOCRReading: Sendable {
    /// Whether OCR can run right now (Screen Recording permission granted).
    var isAuthorized: Bool { get }
    func recognizeText(target: InjectionTarget) async throws -> String
}

/// `ContextCapturing` implementation (015 FR-002/003/004): refuse over secure
/// fields BEFORE any read, AX tree first, OCR fallback when AX is thin and
/// authorized. Returns budgeted, memory-only context.
public final class ContextCaptureService: ContextCapturing, Sendable {
    private let ocr: WindowOCRReading?

    public init(ocr: WindowOCRReading? = nil) {
        self.ocr = ocr
    }

    public func capture(target: InjectionTarget) async throws -> CapturedContext {
        // FR-004: refuse — never degrade — over secure input / password fields.
        if SecureFieldDetector.secureInputActive() {
            throw ContextCaptureError.secureField
        }
        let focusedRole = await MainActor.run { SecureFieldDetector.focusedElementRole() }
        if case .refuse = SecureFieldPolicy.decide(secureInputEnabled: false, focusedElementRole: focusedRole) {
            throw ContextCaptureError.secureField
        }
        guard AXIsProcessTrusted() else {
            throw ContextCaptureError.accessibilityDenied
        }

        // AX walk off the main actor (synchronous AX IPC; see AXContextReader).
        let axContext = await Task.detached(priority: .userInitiated) {
            AXContextReader.read(target: target)
        }.value

        if let axContext, !axContext.isThin {
            return axContext
        }

        // Thin AX → OCR fallback when available + authorized (FR-003).
        if let ocr, ocr.isAuthorized,
           let text = try? await ocr.recognizeText(target: target),
           !text.isEmpty {
            let strategy = ContextBudget.strategy(isTerminal: target.isTerminal)
            return CapturedContext(
                source: .ocr,
                appBundleID: target.bundleID,
                windowTitle: axContext?.windowTitle,
                fieldLabel: axContext?.fieldLabel,
                fieldValue: axContext?.fieldValue,
                fieldPlaceholder: axContext?.fieldPlaceholder,
                fieldRole: axContext?.fieldRole,
                windowText: ContextBudget.clip(text, strategy: strategy)
            )
        }

        // Thin but non-empty AX is still better than nothing (a labeled form
        // field alone can be enough); literally empty → honest error (FR-017).
        if let axContext, !axContext.isEmptyOfText {
            return axContext
        }
        throw ContextCaptureError.empty
    }
}
