import Foundation
import BarkCore
import BarkEngines

#if MLXCleanup
import BarkCleanupMLX
#endif

/// Single place where concrete engines are chosen and wired. Swap an STT engine
/// or cleaner here without touching the pipeline (ADR-002 / ADR-003 / ADR-006).
@MainActor
enum CompositionRoot {
    static func makeController() -> DictationController {
        let settings = SettingsStore()
        let permissions = PermissionsCoordinator()
        let hotkey = HotkeyManager()                 // push-to-talk; restored from settings in activate()
        let handsFreeHotkey = HotkeyManager()        // hands-free toggle

        // The chosen STT backend is read from settings; the factory returns the
        // Apple engine if the persisted backend isn't compiled in (defensive —
        // a setting from a future build can never brick the app).
        let stt: STTEngine = STTEngineFactory.make(
            id: settings.settings.sttBackend,
            manifest: STTEngineFactory.bundledManifest(for: settings.settings.sttBackend),
            downloader: ModelDownloader()
        )

        let history: HistoryStore = EncryptedHistoryStore()

        // Speaker gate (011). The embedder is the FluidAudio WeSpeaker model in the
        // full build and a throwing no-op in the lean build (callers fail open). A
        // bundled `manifest-speaker.json`, when present, pins the integrity-verified
        // model bundle; absent it, the embedder uses its dev-only load path.
        let speakerManifest = Bundle.main.url(forResource: "manifest-speaker", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(ModelManifest.self, from: $0) }
        let speakerEmbedder: SpeakerEmbedder = FluidAudioSpeakerEmbedder(
            manifest: speakerManifest,
            downloader: ModelDownloader()
        )
        let speakerStore: SpeakerProfileStore = EncryptedSpeakerProfileStore()

        let llm: TextCleaner?
        #if MLXCleanup
        llm = MLXTextCleaner()   // MLXTextCleaner.defaultModelID
        #else
        llm = nil   // LLM rewrite modes fall back to the deterministic cleaner
        #endif

        return DictationController(
            settings: settings,
            permissions: permissions,
            hotkey: hotkey,
            stt: stt,
            handsFreeHotkey: handsFreeHotkey,
            llmCleaner: llm,
            history: history,
            speakerEmbedder: speakerEmbedder,
            speakerProfileStore: speakerStore
        )
    }
}