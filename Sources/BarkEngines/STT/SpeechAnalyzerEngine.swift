import Foundation
@preconcurrency import AVFoundation
import Speech
import BarkCore

/// `STTEngine` backed by Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber`
/// (macOS 26). Lowest latency, runs on the ANE, zero bundled model weight, and
/// fully offline once the locale asset is installed (ADR-002, ef-ai-ml pick).
///
/// A fresh `SpeechTranscriber` + `SpeechAnalyzer` is built per `beginStream`,
/// because an analyzer session and its `results` sequence are single-use —
/// reusing them would break the 2nd dictation (ADV-007). `prepare` only
/// validates the locale and installs the asset.
///
/// Swap in `ParakeetEngine` / `WhisperKitEngine` later by conforming to the same
/// protocol — nothing else in the app changes.
public actor SpeechAnalyzerEngine: STTEngine {
    private let sourceFormat: AVAudioFormat  // what AudioCaptureEngine emits: 16 kHz mono
    private var localeID = "en-US"
    private var isPrepared = false

    // Per-session state (rebuilt each beginStream, torn down on finish/cancel).
    private var analyzer: SpeechAnalyzer?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    public init() {
        self.sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCaptureEngine.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    public func prepare(locale: String) async throws {
        let loc = Locale(identifier: locale)
        let bcp47 = loc.identifier(.bcp47)

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == bcp47 }) else {
            throw STTError.localeUnsupported(locale: locale)
        }

        // Install the locale asset on first use (the ONLY network event; offline
        // thereafter — see security T-010 / SEC-003).
        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if !installed.contains(bcp47) {
            let probe = makeTranscriber(locale: loc)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
        }

        self.localeID = locale
        self.isPrepared = true
        BarkLog.stt.info("SpeechAnalyzer prepared for \(bcp47, privacy: .public)")
    }

    public func beginStream() async throws -> AsyncThrowingStream<STTResult, Error> {
        guard isPrepared else { throw STTError.notPrepared }

        // Fresh session every time.
        let transcriber = makeTranscriber(locale: Locale(identifier: localeID))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.converter = (format != nil && format != sourceFormat)
            ? AVAudioConverter(from: sourceFormat, to: format!)
            : nil

        let (inStream, inCont) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inCont
        try await analyzer.start(inputSequence: inStream)

        let (out, outCont) = AsyncThrowingStream<STTResult, Error>.makeStream()
        let results = transcriber.results
        resultsTask = Task {
            do {
                for try await result in results {
                    outCont.yield(STTResult(text: String(result.text.characters), isFinal: result.isFinal))
                }
                outCont.finish()
            } catch {
                outCont.finish(throwing: error)
            }
        }
        return out
    }

    public func feed(_ frames: AudioFrames) async {
        guard let inputContinuation, let analyzerFormat else { return }
        guard let source = makeSourceBuffer(frames) else { return }
        let buffer: AVAudioPCMBuffer
        if let converter, let converted = convert(source, with: converter, to: analyzerFormat) {
            buffer = converted
        } else {
            buffer = source
        }
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    public func finishStream() async throws {
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        teardown()
    }

    public func cancel() async {
        resultsTask?.cancel()
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        teardown()
    }

    private func teardown() {
        resultsTask = nil
        inputContinuation = nil
        analyzer = nil
        converter = nil
        analyzerFormat = nil
    }

    // MARK: - Helpers

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    private func makeSourceBuffer(_ frames: AudioFrames) -> AVAudioPCMBuffer? {
        let count = frames.samples.count
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        frames.samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: count)
        }
        return buffer
    }

    private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let gate = ConverterGate()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if gate.supplied { inStatus.pointee = .noDataNow; return nil }
            gate.supplied = true
            inStatus.pointee = .haveData
            return input
        }
        return status == .error ? nil : out
    }
}
