import Foundation

/// Reads the frontmost app's on-screen context (015). Concrete impl
/// (`ContextCaptureService`: AX first, OCR fallback) lives in `BarkEngines`;
/// tests inject a fake. Implementations MUST refuse over secure fields and
/// MUST return already-budgeted text (`ContextBudget`).
public protocol ContextCapturing: Sendable {
    func capture(target: InjectionTarget) async throws -> CapturedContext
}

public enum ContextCaptureError: Error, Sendable, Equatable {
    case secureField           // secure input active / password field focused — refuse, don't degrade
    case accessibilityDenied   // AX permission missing
    case empty                 // AX and OCR both yielded nothing usable
}
