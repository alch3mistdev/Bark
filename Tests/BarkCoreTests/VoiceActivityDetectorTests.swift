import XCTest
@testable import BarkCore

final class VoiceActivityDetectorTests: XCTestCase {
    private let cfg = VADConfig(energyThreshold: 0.1, onsetFrames: 2, hangoverFrames: 3)

    func testRMS() {
        XCTAssertEqual(VoiceActivityDetector.rms([]), 0)
        XCTAssertEqual(VoiceActivityDetector.rms([0.5, 0.5, 0.5]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(VoiceActivityDetector.rms([1, -1, 1, -1]), 1, accuracy: 1e-6)
    }

    func testOnsetRequiresSustainedSpeech() {
        var vad = VoiceActivityDetector(config: cfg)
        XCTAssertEqual(vad.process(rms: 0.5), .none)          // 1 speech frame — not enough
        XCTAssertEqual(vad.process(rms: 0.5), .speechStarted) // 2nd consecutive → onset
        XCTAssertTrue(vad.isSpeaking)
    }

    func testBriefNoiseDoesNotTrigger() {
        var vad = VoiceActivityDetector(config: cfg)
        XCTAssertEqual(vad.process(rms: 0.5), .none)   // single loud frame
        XCTAssertEqual(vad.process(rms: 0.0), .none)   // back to silence → run resets
        XCTAssertEqual(vad.process(rms: 0.5), .none)   // count restarts
        XCTAssertFalse(vad.isSpeaking)
    }

    func testEndAfterSilenceHangover() {
        var vad = VoiceActivityDetector(config: cfg)
        vad.process(rms: 0.5); vad.process(rms: 0.5)   // speaking
        XCTAssertTrue(vad.isSpeaking)
        XCTAssertEqual(vad.process(rms: 0.0), .none)   // silence 1
        XCTAssertEqual(vad.process(rms: 0.0), .none)   // silence 2
        XCTAssertEqual(vad.process(rms: 0.0), .speechEnded) // silence 3 = hangover
        XCTAssertFalse(vad.isSpeaking)
    }

    func testSpeechResetsSilenceRun() {
        var vad = VoiceActivityDetector(config: cfg)
        vad.process(rms: 0.5); vad.process(rms: 0.5)   // speaking
        vad.process(rms: 0.0); vad.process(rms: 0.0)   // 2 silence
        XCTAssertEqual(vad.process(rms: 0.5), .none)   // speech again → silence run resets
        XCTAssertTrue(vad.isSpeaking)
        XCTAssertEqual(vad.process(rms: 0.0), .none)   // only 1 silence now
        XCTAssertEqual(vad.process(rms: 0.0), .none)
        XCTAssertEqual(vad.process(rms: 0.0), .speechEnded)
    }

    func testMultipleUtterances() {
        var vad = VoiceActivityDetector(config: cfg)
        // utterance 1
        XCTAssertEqual(vad.process(rms: 0.3), .none)
        XCTAssertEqual(vad.process(rms: 0.3), .speechStarted)
        for _ in 0..<2 { vad.process(rms: 0) }
        XCTAssertEqual(vad.process(rms: 0), .speechEnded)
        // utterance 2
        XCTAssertEqual(vad.process(rms: 0.3), .none)
        XCTAssertEqual(vad.process(rms: 0.3), .speechStarted)
    }

    func testSensitivityThresholds() {
        XCTAssertGreaterThan(VADSensitivity.low.energyThreshold, VADSensitivity.high.energyThreshold)
    }
}
