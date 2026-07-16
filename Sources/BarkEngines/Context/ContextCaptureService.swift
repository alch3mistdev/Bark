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
    private let axReader: @Sendable (InjectionTarget) -> CapturedContext?
    private let secureInputActive: @Sendable () -> Bool
    private let focusedRole: @MainActor () -> String?
    private let axTrusted: @Sendable () -> Bool

    /// Seams default to the real OS adapters; tests inject fakes to exercise
    /// the refusal/fallback decision tree headlessly.
    public init(
        ocr: WindowOCRReading? = nil,
        axReader: @escaping @Sendable (InjectionTarget) -> CapturedContext? = { AXContextReader.read(target: $0) },
        secureInputActive: @escaping @Sendable () -> Bool = { SecureFieldDetector.secureInputActive() },
        focusedRole: @escaping @MainActor () -> String? = { SecureFieldDetector.focusedElementRole() },
        axTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.ocr = ocr
        self.axReader = axReader
        self.secureInputActive = secureInputActive
        self.focusedRole = focusedRole
        self.axTrusted = axTrusted
    }

    public func capture(target: InjectionTarget) async throws -> CapturedContext {
        // FR-004: refuse — never degrade — over secure input / password fields.
        if secureInputActive() {
            throw ContextCaptureError.secureField
        }
        let role = await MainActor.run { focusedRole() }
        if case .refuse = SecureFieldPolicy.decide(secureInputEnabled: false, focusedElementRole: role) {
            throw ContextCaptureError.secureField
        }
        guard axTrusted() else {
            throw ContextCaptureError.accessibilityDenied
        }

        // AX walk off the main actor (synchronous AX IPC; see AXContextReader).
        let axContext = await Task.detached(priority: .userInitiated) { [axReader] in
            axReader(target)
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
