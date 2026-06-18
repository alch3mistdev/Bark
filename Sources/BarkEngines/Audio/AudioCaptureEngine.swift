import Foundation
@preconcurrency import AVFoundation
import BarkCore

/// Captures the microphone and emits 16 kHz mono Float32 `AudioFrames`.
///
/// Pipeline (mitigates ARCH-003 — never block the realtime audio thread):
///   AVAudioEngine input tap  →  convert to 16 kHz mono  →  lock-free ring buffer
///                                                            ↓  (consumer Task)
///                                                       AsyncStream<AudioFrames>
///
/// The tap does bounded, pre-allocated conversion and a non-blocking ring write;
/// a separate consumer Task drains the ring and yields frames. Mic is opened only
/// while dictating and fully torn down on `stop()` (T-002 / T-012).
/// One-shot flag for `AVAudioConverter` input blocks (Swift 6 treats them as
/// `@Sendable`, so a captured `var` would warn; a class property does not).
final class ConverterGate: @unchecked Sendable {
    var supplied = false
}

public final class AudioCaptureEngine: AudioCapturing, @unchecked Sendable {
    public static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let ring = AudioRingBuffer(capacity: Int(targetSampleRate) * 30) // 30 s headroom
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var consumer: Task<Void, Never>?
    private var continuation: AsyncStream<AudioFrames>.Continuation?
    private var sequence: UInt64 = 0
    private let chunkFrames = 1_600 // ~100 ms at 16 kHz

    public init() {}

    public var droppedSampleCount: Int { ring.droppedSampleCount }

    /// Begins capture and returns a stream of converted frames.
    public func start() throws -> AsyncStream<AudioFrames> {
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw STTError.engineFailure("no microphone input available")
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw STTError.engineFailure("could not build 16 kHz mono format")
        }
        self.targetFormat = target
        self.converter = AVAudioConverter(from: hwFormat, to: target)
        self.sequence = 0

        let (stream, cont) = AsyncStream<AudioFrames>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = cont

        input.installTap(onBus: 0, bufferSize: 4_096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }

        engine.prepare()
        try engine.start()

        // Consumer: drain the ring in ~100 ms chunks, off the realtime thread.
        consumer = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let samples = self.ring.read(maxCount: self.chunkFrames)
                if samples.isEmpty {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }
                self.sequence &+= 1
                self.continuation?.yield(AudioFrames(samples: samples,
                                                     sampleRate: Self.targetSampleRate,
                                                     sequence: self.sequence))
            }
        }
        return stream
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // Flush any tail samples, then close the stream.
        let tail = ring.drain()
        if !tail.isEmpty {
            sequence &+= 1
            continuation?.yield(AudioFrames(samples: tail, sampleRate: Self.targetSampleRate, sequence: sequence))
        }
        continuation?.finish()
        continuation = nil
        converter = nil
    }

    // MARK: - Realtime tap

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let gate = ConverterGate()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if gate.supplied {
                inStatus.pointee = .noDataNow
                return nil
            }
            gate.supplied = true
            inStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channel = out.floatChannelData else { return }
        let count = Int(out.frameLength)
        guard count > 0 else { return }
        // Non-blocking write; overflow is counted, never blocks the audio thread.
        ring.write(UnsafeBufferPointer(start: channel[0], count: count))
    }
}
