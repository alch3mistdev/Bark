import Foundation
@testable import BarkCore
@testable import BarkEngines

// These fakes are driven serially by the controller's pipeline (one dictation at
// a time), so plain stored state under `@unchecked Sendable` is sufficient for
// tests — no locking needed.

/// Canned STT: yields one final segment when the stream is finished.
final class FakeSTTEngine: STTEngine, @unchecked Sendable {
    let finalText: String
    let prepareError: Error?
    private var cont: AsyncThrowingStream<STTResult, Error>.Continuation?

    init(finalText: String = "hello world", prepareError: Error? = nil) {
        self.finalText = finalText
        self.prepareError = prepareError
    }

    func prepare(locale: String) async throws { if let prepareError { throw prepareError } }

    func beginStream() async throws -> AsyncThrowingStream<STTResult, Error> {
        let (stream, c) = AsyncThrowingStream<STTResult, Error>.makeStream()
        cont = c
        return stream
    }

    func feed(_ frames: AudioFrames) async {}

    func finishStream() async throws {
        if !finalText.isEmpty { cont?.yield(STTResult(text: finalText, isFinal: true)) }
        cont?.finish()
        cont = nil
    }

    func cancel() async {
        cont?.finish()
        cont = nil
    }
}

/// Microphone stub: opens an empty stream, closed on stop.
final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
    let startError: Error?
    private var cont: AsyncStream<AudioFrames>.Continuation?

    init(startError: Error? = nil) { self.startError = startError }

    func start() throws -> AsyncStream<AudioFrames> {
        if let startError { throw startError }
        let (stream, c) = AsyncStream<AudioFrames>.makeStream()
        cont = c
        return stream
    }

    func stop() {
        cont?.finish()
        cont = nil
    }
}

/// Cleaner that returns canned text, fails, or hangs (to test the deadline).
final class FakeCleaner: TextCleaner, @unchecked Sendable {
    enum Behavior { case ok(String), fail, hang }
    let behavior: Behavior
    let available: Bool

    init(_ behavior: Behavior, available: Bool = true) {
        self.behavior = behavior
        self.available = available
    }

    var isAvailable: Bool { get async { available } }

    func clean(_ text: String, mode: Mode) async throws -> String {
        switch behavior {
        case .ok(let s): return s
        case .fail: throw CleanupError.modelUnavailable
        case .hang: try await Task.sleep(for: .seconds(60)); return text
        }
    }
}

/// Injector that records text, or fails a configurable number of times.
final class FakeInjector: TextInjector, @unchecked Sendable {
    enum FailMode { case none, secure, focusChanged }
    private let failMode: FailMode
    private var failuresLeft: Int
    private var recorded: [String] = []

    init(_ failMode: FailMode = .none, failTimes: Int = 0) {
        self.failMode = failMode
        self.failuresLeft = failMode == .none ? 0 : failTimes
    }

    var last: String? { recorded.last }
    var count: Int { recorded.count }

    func inject(_ text: String, plan: InjectionPlan) async throws {
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw failMode == .secure ? InjectionError.secureFieldBlocked : InjectionError.focusChanged
        }
        recorded.append(text)
    }
}
