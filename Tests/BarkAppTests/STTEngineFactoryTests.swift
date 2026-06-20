import XCTest
@testable import BarkCore
@testable import BarkEngines

final class STTEngineFactoryTests: XCTestCase {

    func testAppleBackendAlwaysCompilesIn() {
        XCTAssertTrue(STTBackendID.apple.isCompiledIn)
    }

    func testStubBackendsReportNotCompiledInLeanBuild() {
        // The lean Package.swift has no WHISPERKIT / FLUIDAUDIO flags, so the
        // backends are stubbed. This is the contract the Settings UI relies on
        // when hiding the picker entries.
        if !STTBackendCompilationFlags.whisperKit {
            XCTAssertFalse(STTBackendID.whisperkit.isCompiledIn)
        }
        if !STTBackendCompilationFlags.fluidAudio {
            XCTAssertFalse(STTBackendID.parakeet.isCompiledIn)
        }
    }

    func testFactoryReturnsAppleEngineForAppleID() {
        let engine = STTEngineFactory.make(id: .apple)
        XCTAssertNotNil(engine as? SpeechAnalyzerEngine)
    }

    func testFactoryFallsBackToAppleWhenBackendNotCompiledIn() {
        // If whisperkit isn't compiled in but the user has it persisted as the
        // chosen backend, the factory MUST return the Apple engine rather than
        // crashing. The UI relies on this to keep working after switching
        // between Package.swift / Package-stt-extras.swift builds.
        let engine = STTEngineFactory.make(id: .whisperkit)
        // Either a real WhisperKit engine (Package-stt-extras build) or the
        // Apple fallback (lean build) — both keep the pipeline running.
        if STTBackendCompilationFlags.whisperKit {
            XCTAssertTrue(type(of: engine) == WhisperKitEngine.self
                          || engine is WhisperKitEngine)
        } else {
            XCTAssertTrue(engine is SpeechAnalyzerEngine,
                          "expected Apple fallback, got \(type(of: engine))")
        }
    }

    func testBackendPickerHidesUncompiledBackends() {
        // Whatever the UI shows is `allCases.filter { $0.isCompiledIn }`.
        let visible = STTBackendID.allCases.filter { $0.isCompiledIn }
        XCTAssertTrue(visible.contains(.apple))
        XCTAssertEqual(visible.contains(.whisperkit), STTBackendCompilationFlags.whisperKit)
        XCTAssertEqual(visible.contains(.parakeet), STTBackendCompilationFlags.fluidAudio)
    }

    func testBackendIDsArePersistable() throws {
        // The setting is JSON-serialized; a future backend addition must not
        // break older payloads. We can't test backward compat without old data,
        // but we can test the current shape survives a round trip.
        for id in STTBackendID.allCases {
            let data = try JSONEncoder().encode(id)
            let decoded = try JSONDecoder().decode(STTBackendID.self, from: data)
            XCTAssertEqual(decoded, id)
        }
    }

    func testDisplayNamesAreNonEmpty() {
        for id in STTBackendID.allCases {
            XCTAssertFalse(id.displayName.isEmpty)
            XCTAssertFalse(id.blurb.isEmpty)
        }
    }
}