import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// US2 + fail-open coverage for the hands-free speaker gate (011). Uses a fake
/// embedder + in-memory profile store, so it runs in the lean test build with no
/// FluidAudio dependency.
@MainActor
final class HandsFreeSpeakerGateTests: XCTestCase {
    // An utterance long enough (> 1.0 s captured) to actually be gated.
    private let longUtterance = [Float](repeating: 0.3, count: 20) + [Float](repeating: 0, count: 12)
    private let modelID = "fake-embedder"

    private func centroid() -> SpeakerEmbedding { SpeakerEmbedding([1, 0, 0, 0]).l2normalized() }

    private func enrolledProfile(modelID: String? = nil) -> SpeakerProfile {
        SpeakerProfile(centroid: centroid(), sampleCount: 5, enrolledAt: Date(),
                       modelID: modelID ?? self.modelID)
    }

    private func make(
        script: [Float],
        injector: FakeInjector,
        embedder: SpeakerEmbedder?,
        store: InMemorySpeakerProfileStore,
        gateEnabled: Bool,
        sensitivity: SpeakerVerificationSensitivity = .medium
    ) async -> DictationController {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "hfg-\(UUID().uuidString)")!, key: "k")
        settings.update {
            $0.selectedModeID = "clean"
            $0.speakerGateEnabled = gateEnabled
            $0.speakerSensitivity = sensitivity
        }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        let c = DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(finalText: "hello world"), handsFreeHotkey: HotkeyManager(),
            llmCleaner: nil, history: nil,
            speakerEmbedder: embedder, speakerProfileStore: store,
            audioFactory: { ScriptedAudioCapture(rmsLevels: script) },
            pasteInjector: injector, keystrokeInjector: injector,
            targetProvider: { InjectionTarget(pid: 1, bundleID: "com.example.app") }
        )
        await c.warmModel()
        await c.loadSpeakerProfile()
        return c
    }

    private func wait(_ predicate: @escaping () -> Bool) async -> Bool {
        for _ in 0..<200 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }

    // MARK: - Accept: enrolled user's own voice → inject (US2 scenario 1)

    func testMatchingVoiceIsInjected() async {
        let injector = FakeInjector()
        let embedder = FakeSpeakerEmbedder(.embedding(centroid()))   // identical → cosine 1.0
        let store = InMemorySpeakerProfileStore(enrolledProfile())
        let c = await make(script: longUtterance, injector: injector, embedder: embedder, store: store, gateEnabled: true)
        XCTAssertTrue(c.speakerEnrolled)

        c.startHandsFree()
        let injected = await wait { injector.count >= 1 }
        XCTAssertTrue(injected)
        XCTAssertEqual(injector.last, "Hello world")
        c.stopHandsFree()
    }

    // MARK: - Reject: a different voice → no injection, keep listening (US2 scenarios 2/3)

    func testNonMatchingVoiceIsDeclinedAndSessionContinues() async {
        let injector = FakeInjector()
        let embedder = FakeSpeakerEmbedder(.embedding(SpeakerEmbedding([0, 1, 0, 0])))  // orthogonal → cosine 0
        let store = InMemorySpeakerProfileStore(enrolledProfile())
        let c = await make(script: longUtterance, injector: injector, embedder: embedder, store: store, gateEnabled: true)

        c.startHandsFree()
        let embedded = await wait { embedder.callCount >= 1 }
        XCTAssertTrue(embedded, "the gate should have evaluated the utterance")
        try? await Task.sleep(for: .milliseconds(150))   // give any (wrong) injection a chance to land
        XCTAssertEqual(injector.count, 0, "a different speaker must not be typed")
        XCTAssertTrue(c.handsFreeActive, "declining is normal — the session keeps listening")
        c.stopHandsFree()
    }

    // MARK: - Fail-open paths (FR-009 / SC-006)

    func testEmbedderErrorFailsOpen() async {
        let injector = FakeInjector()
        let embedder = FakeSpeakerEmbedder(.failure)
        let store = InMemorySpeakerProfileStore(enrolledProfile())
        let c = await make(script: longUtterance, injector: injector, embedder: embedder, store: store, gateEnabled: true)

        c.startHandsFree()
        let injected = await wait { injector.count >= 1 }
        XCTAssertTrue(injected, "an embedder error must never block the user's own dictation")
        c.stopHandsFree()
    }

    func testGateEnabledButNotEnrolledFailsOpen() async {
        let injector = FakeInjector()
        let embedder = FakeSpeakerEmbedder(.embedding(SpeakerEmbedding([0, 1, 0, 0])))  // would reject if consulted
        let store = InMemorySpeakerProfileStore(nil)                                    // no voiceprint
        let c = await make(script: longUtterance, injector: injector, embedder: embedder, store: store, gateEnabled: true)
        XCTAssertFalse(c.speakerEnrolled)

        c.startHandsFree()
        let injected = await wait { injector.count >= 1 }
        XCTAssertTrue(injected)
        XCTAssertEqual(embedder.callCount, 0, "no profile → gate never runs the embedder")
        c.stopHandsFree()
    }

    func testGateDisabledInjectsRegardless() async {
        let injector = FakeInjector()
        let embedder = FakeSpeakerEmbedder(.embedding(SpeakerEmbedding([0, 1, 0, 0])))  // would reject if consulted
        let store = InMemorySpeakerProfileStore(enrolledProfile())
        let c = await make(script: longUtterance, injector: injector, embedder: embedder, store: store, gateEnabled: false)

        c.startHandsFree()
        let injected = await wait { injector.count >= 1 }
        XCTAssertTrue(injected)
        XCTAssertEqual(embedder.callCount, 0, "gate off → embedder never called")
        c.stopHandsFree()
    }

    func testIncompatibleModelIDFailsOpen() async {
        let injector = FakeInjector()
        let embedder = FakeSpeakerEmbedder(.embedding(SpeakerEmbedding([0, 1, 0, 0])))
        let store = InMemorySpeakerProfileStore(enrolledProfile(modelID: "old-model"))  // stale voiceprint
        let c = await make(script: longUtterance, injector: injector, embedder: embedder, store: store, gateEnabled: true)
        XCTAssertFalse(c.speakerEnrolled, "incompatible voiceprint reads as not enrolled")

        c.startHandsFree()
        let injected = await wait { injector.count >= 1 }
        XCTAssertTrue(injected)
        XCTAssertEqual(embedder.callCount, 0)
        c.stopHandsFree()
    }

    // MARK: - Delete voiceprint

    func testDeleteVoiceprintDisablesGate() async {
        let injector = FakeInjector()
        let embedder = FakeSpeakerEmbedder(.embedding(centroid()))
        let store = InMemorySpeakerProfileStore(enrolledProfile())
        let c = await make(script: [Float](repeating: 0, count: 4), injector: injector,
                           embedder: embedder, store: store, gateEnabled: true)
        XCTAssertTrue(c.speakerEnrolled)
        await c.deleteVoiceprint()
        XCTAssertFalse(c.speakerEnrolled)
        let reloaded = await store.load()
        XCTAssertNil(reloaded)
    }
}
