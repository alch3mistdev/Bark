import Foundation
import BarkCore
import BarkEngines

#if MLXCleanup
import BarkCleanupMLX
#endif

/// Single place where concrete engines are chosen and wired. Swap an STT engine
/// or cleaner here without touching the pipeline (ADR-002 / ADR-003).
@MainActor
enum CompositionRoot {
    static func makeController() -> DictationController {
        let settings = SettingsStore()
        let permissions = PermissionsCoordinator()
        let hotkey = HotkeyManager()                 // push-to-talk; restored from settings in activate()
        let handsFreeHotkey = HotkeyManager()        // hands-free toggle
        let stt: STTEngine = SpeechAnalyzerEngine()  // Apple on-device, macOS 26
        let history: HistoryStore = EncryptedHistoryStore()

        // Smart Replies (009): read the focused app on-device, only when opted in.
        let contextProvider: ContextProvider = AccessibilityContextReader()

        let llm: TextCleaner?
        let branchSuggester: BranchSuggester?
        #if MLXCleanup
        // One shared model: cleanup rewrite + reply suggestions reuse a single
        // Qwen3-4B download and in-memory container.
        let host = MLXModelHost(modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        llm = MLXTextCleaner(host: host)
        branchSuggester = MLXBranchSuggester(host: host)
        #else
        llm = nil               // LLM rewrite modes fall back to the deterministic cleaner
        branchSuggester = nil   // Smart Replies falls back to deterministic quick replies
        #endif

        return DictationController(
            settings: settings,
            permissions: permissions,
            hotkey: hotkey,
            stt: stt,
            handsFreeHotkey: handsFreeHotkey,
            llmCleaner: llm,
            history: history,
            branchSuggester: branchSuggester,
            contextProvider: contextProvider
        )
    }
}
