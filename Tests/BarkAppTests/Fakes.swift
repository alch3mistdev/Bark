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

    // 012: refine mirrors `behavior` (a canned rewrite / fail / hang).
    func refine(_ text: String, instruction: String, mode: Mode) async throws -> String {
        switch behavior {
        case .ok(let s): return s
        case .fail: throw CleanupError.modelUnavailable
        case .hang: try await Task.sleep(for: .seconds(60)); return text
        }
    }
}

/// 012: STT that yields the next scripted segment text on each `finishStream`,
/// so the multi-segment refine loop gets distinct base / instruction / tail
/// transcripts from one open mic.
final class ScriptedSTTEngine: STTEngine, @unchecked Sendable {
    private let segments: [String]
    private var index = 0
    private var cont: AsyncThrowingStream<STTResult, Error>.Continuation?

    init(segments: [String]) { self.segments = segments }

    func prepare(locale: String) async throws {}

    func beginStream() async throws -> AsyncThrowingStream<STTResult, Error> {
        let (stream, c) = AsyncThrowingStream<STTResult, Error>.makeStream()
        cont = c
        return stream
    }

    func feed(_ frames: AudioFrames) async {}

    func finishStream() async throws {
        let text = index < segments.count ? segments[index] : ""
        index += 1
        if !text.isEmpty { cont?.yield(STTResult(text: text, isFinal: true)) }
        cont?.finish()
        cont = nil
    }

    func cancel() async { cont?.finish(); cont = nil }
}

/// STT whose finalize wedges until `cancel()` tears the stream down — models
/// SpeechAnalyzer.finalizeAndFinishThroughEndOfInput hanging on a bad utterance,
/// the failure the finalize deadline must contain.
final class HangingFinishSTTEngine: STTEngine, @unchecked Sendable {
    private var cont: AsyncThrowingStream<STTResult, Error>.Continuation?
    private(set) var cancelCount = 0

    func prepare(locale: String) async throws {}

    func beginStream() async throws -> AsyncThrowingStream<STTResult, Error> {
        let (stream, c) = AsyncThrowingStream<STTResult, Error>.makeStream()
        cont = c
        return stream
    }

    func feed(_ frames: AudioFrames) async {}

    func finishStream() async throws {
        // Wedge until the deadline's work-task cancellation reaches us.
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func cancel() async {
        cancelCount += 1
        cont?.finish()
        cont = nil
    }
}

/// 012: cleaner whose `refine` maps (draft, instruction) → output via a closure,
/// for driving multi-turn refine flow tests. `clean` returns its input.
final class ScriptedRefineCleaner: TextCleaner, @unchecked Sendable {
    private let transform: @Sendable (String, String) -> String
    let available: Bool

    init(available: Bool = true, _ transform: @escaping @Sendable (String, String) -> String) {
        self.transform = transform
        self.available = available
    }

    var isAvailable: Bool { get async { available } }
    func clean(_ text: String, mode: Mode) async throws -> String { text }
    func refine(_ text: String, instruction: String, mode: Mode) async throws -> String {
        transform(text, instruction)
    }
}

/// 012: emits frames continuously until stopped, so the refine capture loop keeps
/// iterating and promptly drains queued left-option boundaries.
final class ContinuousAudioCapture: AudioCapturing, @unchecked Sendable {
    private let level: Float
    private var cont: AsyncStream<AudioFrames>.Continuation?
    private let running = RunningFlag()

    init(level: Float = 0.2) { self.level = level }

    final class RunningFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var isOn: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func off() { lock.lock(); value = false; lock.unlock() }
    }

    func start() throws -> AsyncStream<AudioFrames> {
        let (stream, c) = AsyncStream<AudioFrames>.makeStream()
        cont = c
        let level = self.level
        let running = self.running
        Task {
            var i: UInt64 = 0
            while running.isOn {
                c.yield(AudioFrames(samples: [Float](repeating: level, count: 1600), sequence: i))
                i += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
            c.finish()
        }
        return stream
    }

    func stop() { running.off(); cont?.finish(); cont = nil }
}

/// Emits frames whose RMS equals each scripted level, then stays open until
/// stopped — drives the VAD in hands-free tests.
final class ScriptedAudioCapture: AudioCapturing, @unchecked Sendable {
    private let levels: [Float]
    private let autoFinish: Bool
    private var cont: AsyncStream<AudioFrames>.Continuation?

    /// `autoFinish` finishes the stream after the last frame, simulating an
    /// abnormal end (device loss) where `stop()` is never called.
    init(rmsLevels: [Float], autoFinish: Bool = false) {
        self.levels = rmsLevels
        self.autoFinish = autoFinish
    }

    func start() throws -> AsyncStream<AudioFrames> {
        let (stream, c) = AsyncStream<AudioFrames>.makeStream()
        cont = c
        let levels = self.levels
        let autoFinish = self.autoFinish
        Task {
            for (i, level) in levels.enumerated() {
                // Constant samples → RMS == level.
                let samples = [Float](repeating: level, count: 1600)
                c.yield(AudioFrames(samples: samples, sequence: UInt64(i)))
                try? await Task.sleep(for: .milliseconds(3))
            }
            if autoFinish { c.finish() }   // stream dies on its own; stop() never called
            // else leave the stream open; stop() finishes it
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

/// Speaker embedder that returns a fixed embedding or throws — drives the
/// speaker-gate tests without any FluidAudio dependency (lean test build).
final class FakeSpeakerEmbedder: SpeakerEmbedder, @unchecked Sendable {
    enum Result { case embedding(SpeakerEmbedding), failure }
    private let result: Result
    let modelID: String
    private(set) var callCount = 0

    init(_ result: Result, modelID: String = "fake-embedder") {
        self.result = result
        self.modelID = modelID
    }

    func embed(_ samples: [Float]) async throws -> SpeakerEmbedding {
        callCount += 1
        switch result {
        case .embedding(let e): return e
        case .failure: throw STTError.engineFailure("fake embedder failure")
        }
    }
}

/// In-memory voiceprint store for tests — no crypto, no Keychain, no disk.
final class InMemorySpeakerProfileStore: SpeakerProfileStore, @unchecked Sendable {
    private var profile: SpeakerProfile?
    init(_ profile: SpeakerProfile? = nil) { self.profile = profile }
    func load() async -> SpeakerProfile? { profile }
    func save(_ profile: SpeakerProfile) async throws { self.profile = profile }
    func delete() async { profile = nil }
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
