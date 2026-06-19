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
    let beginStreamError: Error?
    private var cont: AsyncThrowingStream<STTResult, Error>.Continuation?

    init(finalText: String = "hello world", prepareError: Error? = nil, beginStreamError: Error? = nil) {
        self.finalText = finalText
        self.prepareError = prepareError
        self.beginStreamError = beginStreamError
    }

    func prepare(locale: String) async throws { if let prepareError { throw prepareError } }

    func beginStream() async throws -> AsyncThrowingStream<STTResult, Error> {
        if let beginStreamError { throw beginStreamError }
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

/// Emits frames whose RMS equals each scripted level, then stays open until
/// stopped — drives the VAD in hands-free tests.
final class ScriptedAudioCapture: AudioCapturing, @unchecked Sendable {
    private let levels: [Float]
    private var cont: AsyncStream<AudioFrames>.Continuation?

    init(rmsLevels: [Float]) { self.levels = rmsLevels }

    func start() throws -> AsyncStream<AudioFrames> {
        let (stream, c) = AsyncStream<AudioFrames>.makeStream()
        cont = c
        let levels = self.levels
        Task {
            for (i, level) in levels.enumerated() {
                // Constant samples → RMS == level.
                let samples = [Float](repeating: level, count: 1600)
                c.yield(AudioFrames(samples: samples, sequence: UInt64(i)))
                try? await Task.sleep(for: .milliseconds(3))
            }
            // leave the stream open; stop() finishes it
        }
        return stream
    }

    func stop() { cont?.finish(); cont = nil }
}

/// Cleaner with a controllable prepare/download (progress, cancel, success/fail)
/// for exercising the LLM model-lifecycle state machine.
final class FakePreparingCleaner: TextCleaner, @unchecked Sendable {
    enum Outcome { case succeed, fail }
    let outcome: Outcome
    private var loaded = false

    init(_ outcome: Outcome = .succeed) { self.outcome = outcome }

    var isAvailable: Bool { get async { loaded } }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.3)
        try await Task.sleep(for: .milliseconds(30))   // simulated download window
        try Task.checkCancellation()
        progress(1.0)
        if outcome == .fail { throw CleanupError.modelUnavailable }
        loaded = true
    }

    func clean(_ text: String, mode: Mode) async throws -> String {
        guard loaded else { throw CleanupError.modelUnavailable }
        return "LLM:\(text)"
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

/// Injector that suspends inside `inject` until `releaseAll()` is called, so a
/// test can hold an injection "in flight" and prove re-insert serialization.
@MainActor
final class GatedInjector: TextInjector {
    private(set) var count = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    nonisolated init() {}

    func inject(_ text: String, plan: InjectionPlan) async throws {
        count += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
