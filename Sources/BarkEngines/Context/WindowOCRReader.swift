import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision
import BarkCore

/// OCR fallback for context capture (015 FR-003): one ScreenCaptureKit frame
/// of the target app's frontmost window → Vision text recognition, entirely
/// on-device. Gated on Screen Recording permission (`isAuthorized`); requested
/// just-in-time by the UI, never at launch (R10). The captured image lives
/// only inside this call.
public final class WindowOCRReader: WindowOCRReading, Sendable {
    public init() {}

    public var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func recognizeText(target: InjectionTarget) async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Frontmost window of the target app: its windows, topmost (layer 0) first.
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == target.pid && $0.isOnScreen && $0.frame.height > 40
        }) else {
            throw ContextCaptureError.empty
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)    // Retina-scale for OCR accuracy
        configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: configuration)
        return try recognize(image)
    }

    /// Vision pass: accurate recognition, lines joined top-to-bottom.
    private func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }   // Vision Y is bottom-up
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
