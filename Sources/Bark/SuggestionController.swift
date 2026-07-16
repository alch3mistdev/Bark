import Foundation
import Observation
import BarkCore
import BarkEngines

/// Orchestrator for the Suggested Responses flow (015): hotkey → context
/// capture → LLM candidates → overlay pick → injection (or "Other…" → one-shot
/// dictation). Deliberately parallel to `DictationController` (R1) — it
/// consumes only that controller's public seams (`phase`, `handsFreeActive`,
/// `prepareLLM`, `startHandsFree`, `stopHandsFree`) and owns its own hotkey,
/// state machine, injectors, and overlay lifecycle.
///
/// Captured context is ephemeral by contract (FR-005): held only in the
/// in-flight task, never persisted, logged, or written to history.
@MainActor
@Observable
public final class SuggestionController {
    public private(set) var session = SuggestionSession()
    public private(set) var lastError: String?
    public private(set) var lastResult: String?

    /// Wired by the app layer to drive the overlay panel (same pattern as
    /// `DictationController.onPhaseChange` → HUD).
    public var onSessionChange: (@MainActor (SuggestionSession) -> Void)?

    private let settings: SettingsStore
    private let dictation: DictationController
    private let hotkey: HotkeyManager
    private let capture: ContextCapturing
    private let localEngine: SuggestionEngine?
    private let externalEngineProvider: (@MainActor (_ endpoint: String, _ model: String, _ apiKey: String?) -> SuggestionEngine)?
    private let secretStore: SecretStore
    private let history: HistoryStore?
    private let pasteInjector: TextInjector
    private let keystrokeInjector: TextInjector
    private let clipboardInjector: TextInjector
    private let returnSynthesizer: ReturnKeySynthesizing
    private let targetProvider: @MainActor () -> InjectionTarget?
    private let secureInputCheck: @MainActor () -> Bool
    private let generationDeadline: Double
    private let settleDelay: Duration

    private var capturedTarget: InjectionTarget?
    private var flowTask: Task<Void, Never>?
    private var oneShotDictation = false

    /// Keychain account for the external endpoint's API key.
    public static let apiKeyAccount = "external-llm-key"

    public init(
        settings: SettingsStore,
        dictation: DictationController,
        hotkey: HotkeyManager = HotkeyManager(),
        capture: ContextCapturing,
        localEngine: SuggestionEngine?,
        externalEngineProvider: (@MainActor (_ endpoint: String, _ model: String, _ apiKey: String?) -> SuggestionEngine)? = nil,
        secretStore: SecretStore = KeychainSecretStore(),
        history: HistoryStore? = nil,
        pasteInjector: TextInjector = PasteboardInjector(),
        keystrokeInjector: TextInjector = KeystrokeInjector(),
        clipboardInjector: TextInjector = ClipboardInjector(),
        returnSynthesizer: ReturnKeySynthesizing = ReturnKeySynthesizer(),
        targetProvider: @escaping @MainActor () -> InjectionTarget? = { FocusProbe.currentTarget() },
        secureInputCheck: @escaping @MainActor () -> Bool = { SecureFieldDetector.secureInputActive() },
        generationDeadline: Double = 12,
        settleDelay: Duration = .milliseconds(120)
    ) {
        self.settings = settings
        self.dictation = dictation
        self.hotkey = hotkey
        self.capture = capture
        self.localEngine = localEngine
        self.externalEngineProvider = externalEngineProvider
        self.secretStore = secretStore
        self.history = history
        self.pasteInjector = pasteInjector
        self.keystrokeInjector = keystrokeInjector
        self.clipboardInjector = clipboardInjector
        self.returnSynthesizer = returnSynthesizer
        self.targetProvider = targetProvider
        self.secureInputCheck = secureInputCheck
        self.generationDeadline = generationDeadline
        self.settleDelay = settleDelay
    }

    // MARK: - Settings surface (UI binds here; writes persist)

    public var enabled: Bool {
        get { settings.settings.suggestionsEnabled }
        set { settings.update { $0.suggestionsEnabled = newValue } }
    }

    /// 3-way collision guard: the suggestions key must not shadow push-to-talk
    /// or hands-free (extends the pairwise guard in `DictationController`).
    public var hotkeySetting: HotkeySetting {
        get { settings.settings.suggestionsHotkey }
        set {
            guard newValue != settings.settings.hotkey else {
                lastError = "That key is already the push-to-talk hotkey."; return
            }
            guard newValue != settings.settings.handsFreeHotkey else {
                lastError = "That key is already the hands-free hotkey."; return
            }
            settings.update { $0.suggestionsHotkey = newValue }
            hotkey.update(HotkeyConfig(newValue))
        }
    }

    public var backend: SuggestionBackendID {
        get { settings.settings.suggestionBackend }
        set { settings.update { $0.suggestionBackend = newValue } }
    }

    public var externalEndpoint: String {
        get { settings.settings.externalLLMEndpoint }
        set { settings.update { $0.externalLLMEndpoint = newValue } }
    }

    public var externalModel: String {
        get { settings.settings.externalLLMModel }
        set { settings.update { $0.externalLLMModel = newValue } }
    }

    public var autoSubmit: Bool {
        get { settings.settings.suggestionAutoSubmit }
        set { settings.update { $0.suggestionAutoSubmit = newValue } }
    }

    /// API key lives in the Keychain only (FR-013). Empty string clears it.
    public var externalAPIKey: String {
        get { secretStore.read(account: Self.apiKeyAccount) ?? "" }
        set {
            do { try secretStore.write(newValue, account: Self.apiKeyAccount) }
            catch { lastError = "Couldn't save the API key to the Keychain." }
        }
    }

    /// Local backend rides the existing LLM opt-in (R12).
    public var localEngineUsable: Bool {
        localEngine != nil && settings.settings.llmEnabled
    }

    // MARK: - Lifecycle

    /// Bind the suggestions hotkey. A `keyToggle` fires onStart/onStop on
    /// alternating presses — both mean "the key was pressed" here.
    public func activate() {
        hotkey.update(HotkeyConfig(settings.settings.suggestionsHotkey))
        hotkey.onStart = { [weak self] in
            Task { @MainActor in self?.handleHotkey() }
        }
        hotkey.onStop = { [weak self] in
            Task { @MainActor in self?.handleHotkey() }
        }
        hotkey.start()
    }

    public func deactivate() {
        hotkey.stop()
        flowTask?.cancel()
    }

    // MARK: - Flow

    /// Every hotkey press lands here: toggle-dismiss when anything is showing,
    /// otherwise start a pass (FR-001/FR-016).
    public func handleHotkey() {
        guard session.phase == .idle else { dismiss(); return }
        guard settings.settings.suggestionsEnabled else { return }
        guard !dictation.phase.isActive, !dictation.handsFreeActive else { return }
        start()
    }

    private func start() {
        lastError = nil
        guard let target = targetProvider(),
              target.pid != ProcessInfo.processInfo.processIdentifier else { return }  // never suggest into Bark itself
        capturedTarget = target
        session.handle(.hotkeyPressed)
        publish()
        // Warm the shared local model so load overlaps capture (R2).
        if settings.settings.suggestionBackend == .local, localEngineUsable {
            dictation.prepareLLM()
        }
        flowTask = Task { await runFlow(target: target) }
    }

    private func runFlow(target: InjectionTarget) async {
        do {
            let context = try await capture.capture(target: target)
            guard session.phase == .capturing else { return }   // dismissed mid-capture
            session.handle(.contextCaptured)
            publish()

            let snippets = await historySnippets(for: context)
            let request = SuggestionPrompt.build(context: context, historySnippets: snippets)
            let raw = try await generate(request)

            guard session.phase == .generating else { return }  // dismissed mid-generation
            let candidates = SuggestionResponseParser.parse(raw)
            guard !candidates.isEmpty else {
                fail("Couldn't produce suggestions for this screen."); return
            }
            session.handle(.candidatesReady(candidates))
            publish()
        } catch let error as ContextCaptureError {
            guard session.isActive else { return }
            fail(Self.captureMessage(error))
        } catch is CancellationError {
            // dismissed — session already reset
        } catch {
            guard session.isActive else { return }
            fail(Self.generationMessage(error))
        }
    }

    /// Pick the engine per backend setting, run under the hard deadline. The
    /// availability wait covers a warm-up still in flight (edge: hotkey during
    /// model load). External failures fall back to local — never the reverse
    /// (R8: fail toward privacy).
    private func generate(_ request: SuggestionRequest) async throws -> String {
        switch settings.settings.suggestionBackend {
        case .local:
            guard localEngineUsable, let engine = localEngine else {
                throw SuggestionError.engineUnavailable
            }
            return try await run(engine, request)
        case .external:
            guard let engine = makeExternalEngine() else {
                throw SuggestionError.endpointNotConfigured
            }
            do {
                return try await run(engine, request)
            } catch {
                // R8: retry on-device when possible; local errors never escalate
                // to the network.
                if localEngineUsable, let local = localEngine {
                    BarkLog.cleanup.error("external suggestion engine failed; falling back to local")
                    return try await run(local, request)
                }
                throw error
            }
        }
    }

    private func run(_ engine: SuggestionEngine, _ request: SuggestionRequest) async throws -> String {
        try await withThrowingDeadline(seconds: generationDeadline) {
            while !(await engine.isAvailable) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(200))
            }
            return try await engine.suggest(request)
        }
    }

    private func makeExternalEngine() -> SuggestionEngine? {
        let endpoint = settings.settings.externalLLMEndpoint.trimmingCharacters(in: .whitespaces)
        let model = settings.settings.externalLLMModel.trimmingCharacters(in: .whitespaces)
        guard !endpoint.isEmpty, !model.isEmpty, let provider = externalEngineProvider else { return nil }
        let key = secretStore.read(account: Self.apiKeyAccount)
        return provider(endpoint, model, key)
    }

    private func historySnippets(for context: CapturedContext) async -> [String] {
        guard settings.settings.historyEnabled, let history else { return [] }
        let keywords = HistoryRelevance.keywords(
            fieldLabel: context.fieldLabel,
            contextTail: String(context.windowText.suffix(200))
        )
        guard !keywords.isEmpty else { return [] }
        return HistoryRelevance.snippets(from: await history.all(), keywords: keywords)
    }

    // MARK: - Overlay actions

    public func choose(_ index: Int) {
        guard session.handle(.choose(index)) else { return }
        publish()   // overlay hides on .injecting; focus returns to the target
        flowTask = Task { await injectChosen() }
    }

    public func moveHighlight(_ delta: Int) {
        guard session.handle(.moveHighlight(delta)) else { return }
        publish()
    }

    public func acceptHighlighted() {
        guard session.phase == .presenting else { return }
        let wasOther = session.highlightedIndex == session.otherRowIndex
        guard session.handle(.acceptHighlighted) else { return }
        publish()
        if wasOther {
            startOtherDictation()
        } else {
            flowTask = Task { await injectChosen() }
        }
    }

    public func chooseOther() {
        guard session.handle(.chooseOther) else { return }
        publish()
        startOtherDictation()
    }

    public func dismiss() {
        flowTask?.cancel(); flowTask = nil
        if oneShotDictation {
            oneShotDictation = false
            dictation.stopHandsFree()
        }
        capturedTarget = nil
        session.handle(.dismiss)
        publish()
    }

    // MARK: - "Other…" → one-shot dictation (US2)

    /// Reuses the whole hands-free path (VAD → STT → cleanup → inject) for one
    /// utterance (R9). `notifyDictationPhase` (multiplexed from the app layer)
    /// ends the session on the first completed/failed utterance.
    private func startOtherDictation() {
        oneShotDictation = true
        dictation.startHandsFree()
        // startHandsFree refuses (no mic / model not ready) by going .failed —
        // notifyDictationPhase picks that up; if it never even flipped to
        // active, end the session now.
        if !dictation.handsFreeActive {
            oneShotDictation = false
            session.handle(.dictationFinished)
            publish()
        }
    }

    /// Fed every dictation phase change by the app layer (BarkApp multiplex).
    public func notifyDictationPhase(_ phase: DictationPhase) {
        guard oneShotDictation, session.phase == .dictating else { return }
        switch phase {
        case .completed, .failed:
            oneShotDictation = false
            dictation.stopHandsFree()
            session.handle(.dictationFinished)
            publish()
        default:
            break
        }
    }

    // MARK: - Injection

    private func injectChosen() async {
        guard let index = session.chosenIndex,
              session.candidates.indices.contains(index),
              let target = capturedTarget else {
            session.handle(.dismiss); publish(); return
        }
        let text = session.candidates[index]
        // The overlay just resigned key; give focus a beat to return to the
        // target before the preflight compares it (R3).
        try? await Task.sleep(for: settleDelay)

        let sanitized = TextSanitizer.sanitize(
            text,
            options: .init(allowNewlines: !target.isTerminal, stripTrailingNewlines: true)
        )
        guard !sanitized.isEmpty else { finishInjected(); return }
        let strategy = InjectionRouter.strategy(routing: settings.settings.outputRouting,
                                                isTerminal: target.isTerminal)
        let plan = InjectionPlan(target: target, strategy: strategy, stripTrailingNewlines: true)
        do {
            try await injector(for: strategy).inject(sanitized, plan: plan)
            lastResult = sanitized
            if settings.settings.soundFeedback { Feedback.inserted() }
            recordHistory(output: sanitized, target: target)
            await autoSubmitIfApproved(target: target, strategy: strategy)
            finishInjected()
        } catch {
            fail(DictationController.injectionMessage(error))
        }
    }

    /// ADR-010 / FR-012: opt-in Return after a picked suggestion. The pure
    /// policy gates here; `ReturnKeySynthesizer` re-runs the full preflight
    /// immediately before the keypress. Failure is best-effort (the text is
    /// already inserted) — logged, never fatal.
    private func autoSubmitIfApproved(target: InjectionTarget, strategy: InjectionStrategy) async {
        let approved = AutoSubmitPolicy.decide(
            enabled: settings.settings.suggestionAutoSubmit,
            selectionWasExplicit: true,   // only the picked-candidate path reaches this
            strategy: strategy,
            secureInputActive: secureInputCheck(),
            focusUnchanged: FocusGuard.targetUnchanged(captured: target, current: targetProvider())
        )
        guard approved else { return }
        try? await Task.sleep(for: settleDelay)   // let the paste/keystrokes land first
        do {
            try await returnSynthesizer.postReturn(plan: InjectionPlan(target: target, strategy: strategy))
        } catch {
            BarkLog.inject.error("auto-submit refused/failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func injector(for strategy: InjectionStrategy) -> TextInjector {
        switch strategy {
        case .copyOnly:  return clipboardInjector
        case .keystroke: return keystrokeInjector
        case .paste:     return pasteInjector
        }
    }

    private func finishInjected() {
        capturedTarget = nil
        session.handle(.injected)
        publish()
    }

    /// Accepted suggestions are recallable from history WITHOUT persisting any
    /// captured screen content (R7): transcript stays empty.
    private func recordHistory(output: String, target: InjectionTarget) {
        guard settings.settings.historyEnabled, let history else { return }
        let record = HistoryRecord(transcript: "", output: output,
                                   modeID: "suggestion", appBundleID: target.bundleID)
        Task.detached {
            do { try await history.append(record) }
            catch { BarkLog.pipeline.error("suggestion history append failed") }
        }
    }

    // MARK: - Errors

    private func fail(_ message: String) {
        lastError = message
        capturedTarget = nil
        session.handle(.errored(message))
        publish()
    }

    private func publish() {
        onSessionChange?(session)
    }

    static func captureMessage(_ error: ContextCaptureError) -> String {
        switch error {
        case .secureField: return "Not available here — a secure field is focused."
        case .accessibilityDenied: return "Accessibility permission is off — Bark can't read the screen without it."
        case .empty: return "Couldn't read any text on this screen."
        }
    }

    static func generationMessage(_ error: Error) -> String {
        switch error {
        case CleanupError.timedOut:
            return "Suggestions timed out — try again."
        case SuggestionError.engineUnavailable:
            return "Turn on the LLM rewrite in Settings → Models to use on-device suggestions."
        case SuggestionError.endpointNotConfigured:
            return "Configure the custom endpoint in Settings → Suggest."
        case SuggestionError.http(let code):
            return "The endpoint returned HTTP \(code) — check Settings → Suggest."
        case SuggestionError.network:
            return "Couldn't reach the endpoint — check Settings → Suggest."
        case SuggestionError.badResponse:
            return "The endpoint's reply couldn't be read."
        default:
            return "Suggestions failed: \(DictationController.describe(error))"
        }
    }
}
