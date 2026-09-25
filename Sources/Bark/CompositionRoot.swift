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
    /// Build the dictation conductor and the suggestion + discussion
    /// controllers together so they share the settings store, history store,
    /// and (in the MLX build) the ONE loaded LLM residency (015 R1/R2, 017).
    static func makeControllers() -> (dictation: DictationController,
                                      suggestions: SuggestionController,
                                      discussion: DiscussionController) {
        let dictation = makeController()
        let suggestions = SuggestionController(
            settings: dictation.settings,
            dictation: dictation,
            hotkey: HotkeyManager(),
            capture: ContextCaptureService(ocr: WindowOCRReader()),
            localEngine: dictation.sharedSuggestionEngine,
            externalEngineProvider: { endpoint, model, apiKey in
                OpenAICompatClient(endpoint: endpoint, model: model, apiKey: apiKey)
            },
            history: dictation.sharedHistoryStore
        )
        // The discussion runs its own STT instance (the mic lease guarantees
        // it never races dictation's) and its own turn audio engines.
        let discussionSTT: STTEngine = STTEngineFactory.make(
            id: dictation.settings.settings.sttBackend,
            manifest: STTEngineFactory.bundledManifest(for: dictation.settings.settings.sttBackend),
            downloader: ModelDownloader()
        )
        // Spoken replies (017) + opt-in cloud TTS (018, ADR-012). The composite
        // is ALWAYS the speech path: when the backend is the system voice the
        // cloud primary refuses before touching the network, so selecting
        // on-device makes no request at all, and any cloud failure falls back
        // to the local voice (Principle I's required failure direction).
        let systemVoice = AVSpeechSynthesizerEngine()
        let cloudConfig = CloudTTSConfigStore()
        let cloudSynthesizer = ElevenLabsSynthesizer(config: cloudConfig)
        let speech = FallbackSpeechSynthesizer(primary: cloudSynthesizer, fallback: systemVoice)

        let discussion = DiscussionController(
            settings: dictation.settings,
            dictation: dictation,
            hotkey: HotkeyManager(),
            capture: ContextCaptureService(ocr: WindowOCRReader()),
            localEngine: dictation.sharedDialogueEngine,
            externalEngineProvider: { endpoint, model, apiKey in
                OpenAICompatClient(endpoint: endpoint, model: model, apiKey: apiKey)
            },
            stt: discussionSTT,
            synthesizer: speech,
            cloudConfig: cloudConfig,
            cloudTTS: speech,
            voiceFetcher: { try await cloudSynthesizer.fetchVoices() }
        )
        speech.onCloudFailure = { [weak discussion] error in
            Task { @MainActor in
                discussion?.reportCloudTTSFailure(error)
            }
        }
        return (dictation, suggestions, discussion)
    }

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