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
        let permissions = PermissionsCoordinator()
        let hotkey = HotkeyManager()                 // default: hold fn (Globe) to talk
        let stt: STTEngine = SpeechAnalyzerEngine()  // Apple on-device, macOS 26

        let llm: TextCleaner?
        #if MLXCleanup
        llm = MLXTextCleaner(modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        #else
        llm = nil   // LLM rewrite modes fall back to the deterministic cleaner
        #endif

        return DictationController(
            permissions: permissions,
            hotkey: hotkey,
            stt: stt,
            llmCleaner: llm
        )
    }
}
