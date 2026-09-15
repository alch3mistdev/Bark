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
    /// Role of the focused element **within the capture target** — see
    /// `FocusProbe.focusedElementRole(inPID:)` for why this must be
    /// target-scoped rather than system-wide.
    private let focusedRole: @MainActor (InjectionTarget) -> String?
    private let axTrusted: @Sendable () -> Bool
    /// Opts a Chromium/Electron target into exposing its accessibility tree.
    /// Returns true when THIS call did the opting, meaning the app still has
    /// to build the tree before it can be read.
    private let prepareTarget: @Sendable (InjectionTarget) -> Bool
    /// How long to let a freshly opted-in app build its tree. Measured at
    /// ~400 ms in the sibling scrim project; tests set it to zero.
    private let webContentSettleDelay: Duration

    /// Seams default to the real OS adapters; tests inject fakes to exercise
    /// the refusal/fallback decision tree headlessly.
    public init(
        ocr: WindowOCRReading? = nil,
        axReader: @escaping @Sendable (InjectionTarget) -> CapturedContext? = { AXContextReader.read(target: $0) },
        secureInputActive: @escaping @Sendable () -> Bool = { SecureFieldDetector.secureInputActive() },
        focusedRole: @escaping @MainActor (InjectionTarget) -> String? = {
            SecureFieldDetector.focusedElementRole(inPID: $0.pid)
        },
        axTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        prepareTarget: @escaping @Sendable (InjectionTarget) -> Bool = { AXContextReader.prepare(target: $0) },
        webContentSettleDelay: Duration = .milliseconds(400)
    ) {
        self.ocr = ocr
        self.axReader = axReader
        self.secureInputActive = secureInputActive
        self.focusedRole = focusedRole
        self.axTrusted = axTrusted
        self.prepareTarget = prepareTarget
        self.webContentSettleDelay = webContentSettleDelay
    }

    public func capture(target: InjectionTarget) async throws -> CapturedContext {
        // FR-004: refuse — never degrade — over secure input / password fields.
        if secureInputActive() {
            throw ContextCaptureError.secureField
        }
        let role = await MainActor.run { focusedRole(target) }
        if case .refuse = SecureFieldPolicy.decide(secureInputEnabled: false, focusedElementRole: role) {
            throw ContextCaptureError.secureField
        }
        guard axTrusted() else {
            throw ContextCaptureError.accessibilityDenied
        }

        // Chromium/Electron apps expose nothing until asked; the opt-in makes
        // the app BUILD the tree, so the first read after it still sees the
        // old empty one. Pay the settle cost once per process.
        if prepareTarget(target) {
            try? await Task.sleep(for: webContentSettleDelay)
        }

        // AX walk off the main actor (synchronous AX IPC; see AXContextReader).
        let axContext = await Task.detached(priority: .userInitiated) { [axReader] in
            axReader(target)
        }.value

        // Metadata only — never content (constitution I). This is what makes a
        // capture that "does nothing" diagnosable from the log rather than by
        // guesswork.
        BarkLog.pipeline.info("""
            context capture: app \(target.bundleID ?? "?", privacy: .public) \
            axChars \(axContext?.windowText.count ?? -1, privacy: .public) \
            fieldRole \(axContext?.fieldRole ?? "none", privacy: .public) \
            thin \(axContext?.isThin ?? true, privacy: .public) \
            ocrAuthorized \(self.ocr?.isAuthorized ?? false, privacy: .public)
            """)

        // A terminal whose AX gave us only chrome is a FAILED read, however
        // many characters it produced: canvas-rendered terminals expose an
        // empty text area, leaving tab labels and a session sidebar that
        // sail past any length threshold. Fall through to OCR rather than
        // presenting furniture as the screen.
        let chromeOnlyTerminal = target.isTerminal && (axContext?.isChromeOnly ?? false)
        if chromeOnlyTerminal {
            BarkLog.pipeline.info("""
                context capture: \(target.bundleID ?? "?", privacy: .public) is a terminal whose \
                accessibility text is chrome only (canvas renderer) — trying OCR
                """)
        }

        if let axContext, !axContext.isThin, !chromeOnlyTerminal {
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

        // Chrome-only terminal with no OCR available: refuse rather than hand
        // back a session sidebar dressed as the screen. "We read nothing" is
        // recoverable (the caller says so, and points at Screen Recording);
        // furniture presented as content is not — the model reasons
        // confidently about the wrong thing and the user cannot tell.
        if chromeOnlyTerminal {
            throw ContextCaptureError.empty
        }

        // Thin but non-empty AX is still better than nothing (a labeled form
        // field alone can be enough); literally empty → honest error (FR-017).
        if let axContext, !axContext.isEmptyOfText {
            return axContext
        }
        throw ContextCaptureError.empty
    }
}
