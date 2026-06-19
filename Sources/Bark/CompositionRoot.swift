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

        let llm: TextCleaner?
        #if MLXCleanup
        llm = MLXTextCleaner(modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
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
            history: history
        )
    }
}