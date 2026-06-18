import Foundation

/// Microphone capture as a protocol so the pipeline can be driven by a fake in
/// tests (Principle III). `AudioCaptureEngine` is the production conformer.
public protocol AudioCapturing: Sendable {
    /// Begin capture; returns a stream of 16 kHz mono frames.
    func start() throws -> AsyncStream<AudioFrames>
    /// Stop capture and finish the stream.
    func stop()
}
