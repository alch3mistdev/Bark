import Foundation
import Observation
import BarkCore
import BarkEngines

/// Orchestrator for the Socratic discussion flow (017): hotkey → context
/// capture → multi-turn voice dialogue (overlay + optional TTS) → final-prompt
/// synthesis → preview → safe injection into the origin app. Deliberately
/// parallel to `SuggestionController` — it consumes only `DictationController`
/// public seams (`micLeaseHeld`, `handsFreeActive`, `stopHandsFree`,
/// `startHandsFree`, `prepareLLM`, `phase`) and owns its own hotkey, session
/// machine, STT instance, audio engines, and injectors.
///
/// The transcript and captured context are memory-only by contract (FR-010):
/// wiped on session end, never persisted, logged, or written to history.
///
/// In-session, the discussion hotkey (default F7) is the sole key:
/// idle → start session; presenting → skip TTS; awaitingUser (PTT) → start
/// turn; listening (PTT) → end turn. `keyToggle`'s alternating onStart/onStop
/// both land in `handleHotkey()`, exactly the 015 idiom.
///
/// Half-duplex invariant (SC-002): audio capture is started only from states
/// whose `allowsMic` is true, and the only path out of `presenting` is
/// `presentationFinished` — dispatched after `speak()` returns (or at once
/// with TTS off). The mic is therefore provably closed while TTS plays or the
/// engine generates.
@MainActor
@Observable
public final class DiscussionController {
    public private(set) var session = DiscussionSession()
    public private(set) var lastError: String?

    /// Wired by the app layer to drive the overlay panel.
    public var onSessionChange: (@MainActor (DiscussionSession) -> Void)?

    private let settings: SettingsStore
    private let dictation: DictationController
    private let hotkey: HotkeyManager
    private let capture: ContextCapturing
    private let localEngine: DialogueEngine?
    private let externalEngineProvider: (@MainActor (_ endpoint: String, _ model: String, _ apiKey: String?) -> DialogueEngine)?
    private let secretStore: SecretStore
    private let stt: STTEngine
    private let audioFactory: @Sendable () -> AudioCapturing
    private let synthesizer: SpeechSynthesizing?
    private let pasteInjector: TextInjector
    private let keystrokeInjector: TextInjector
    private let clipboardInjector: TextInjector
    private let targetProvider: @MainActor () -> InjectionTarget?
    private let replyDeadline: Double
    private let synthesisDeadline: Double
    private let sttFinalizeDeadline: Double
    private let settleDelay: Duration

    private var capturedTarget: InjectionTarget?
    private var context: CapturedContext?
    private var handsFreeWasActive = false
    /// Invalidates every in-flight task of a torn-down session (015's
    /// `passToken` pattern — callees don't all honor cancellation).
    private var sessionToken = 0
    private var flowTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var injectTask: Task<Void, Never>?

    // PTT turn plumbing (audio + result consumer live across down/up).
    private var pttAudio: AudioCapturing?
    private var pttFeedTask: Task<Void, Never>?
    private var sttConsumer: Task<Void, Never>?
    private var finalSegments: [String] = []
    private var volatileTail = ""

    /// 4 000-char output bound on the synthesized prompt (plan constraint).
    static let synthesizedPromptCharBound = 4000

    public init(
        settings: SettingsStore,
        dictation: DictationController,
        hotkey: HotkeyManager = HotkeyManager(),
        capture: ContextCapturing,
        localEngine: DialogueEngine?,
        externalEngineProvider: (@MainActor (_ endpoint: String, _ model: String, _ apiKey: String?) -> DialogueEngine)? = nil,
        secretStore: SecretStore = KeychainSecretStore(),
        stt: STTEngine,
        audioFactory: @escaping @Sendable () -> AudioCapturing = { AudioCaptureEngine() },
        synthesizer: SpeechSynthesizing? = nil,
        pasteInjector: TextInjector = PasteboardInjector(),
        keystrokeInjector: TextInjector = KeystrokeInjector(),
        clipboardInjector: TextInjector = ClipboardInjector(),
        targetProvider: @escaping @MainActor () -> InjectionTarget? = { FocusProbe.currentTarget() },
        replyDeadline: Double = 20,
        synthesisDeadline: Double = 30,
        sttFinalizeDeadline: Double = 3,
        settleDelay: Duration = .milliseconds(120)
    ) {
        self.settings = settings
        self.dictation = dictation
        self.hotkey = hotkey
        self.capture = capture
        self.localEngine = localEngine
        self.externalEngineProvider = externalEngineProvider
        self.secretStore = secretStore
        self.stt = stt
        self.audioFactory = audioFactory
        self.synthesizer = synthesizer
        self.pasteInjector = pasteInjector
        self.keystrokeInjector = keystrokeInjector
        self.clipboardInjector = clipboardInjector
        self.targetProvider = targetProvider
        self.replyDeadline = replyDeadline
        self.synthesisDeadline = synthesisDeadline
        self.sttFinalizeDeadline = sttFinalizeDeadline
        self.settleDelay = settleDelay
    }

    // MARK: - Settings surface (UI binds here; writes persist)

    public var enabled: Bool {
        get { settings.settings.discussionEnabled }
        set {
            if newValue {
                let hk = settings.settings.discussionHotkey
                guard hk != settings.settings.hotkey, hk != settings.settings.handsFreeHotkey,
                      hk != settings.settings.suggestionsHotkey else {
                    lastError = "The discussion hotkey collides with another Bark hotkey. Pick a different key in Settings first."
                    return
                }
            }
            settings.update { $0.discussionEnabled = newValue }
            newValue ? hotkey.start() : hotkey.stop()
        }
    }

    /// 4-way collision guard, discussion side.
    public var hotkeySetting: HotkeySetting {
        get { settings.settings.discussionHotkey }
        set {
            guard newValue != settings.settings.hotkey else {
                lastError = "That key is already the push-to-talk hotkey."; return
            }
            guard newValue != settings.settings.handsFreeHotkey else {
                lastError = "That key is already the hands-free hotkey."; return
            }
            guard newValue != settings.settings.suggestionsHotkey else {
                lastError = "That key is already the suggestions hotkey."; return
            }
            settings.update { $0.discussionHotkey = newValue }
            hotkey.update(HotkeyConfig(newValue))
        }
    }

    public var micMode: DiscussionMicMode {
        get { settings.settings.discussionMicMode }
        set { settings.update { $0.discussionMicMode = newValue } }
    }

    public var ttsEnabled: Bool {
        get { settings.settings.discussionTTSEnabled }
        set { settings.update { $0.discussionTTSEnabled = newValue } }
    }

    /// Local backend rides the existing LLM opt-in, same rule as 015.
    public var localEngineUsable: Bool {
        localEngine != nil && settings.settings.llmEnabled
    }

    public var engineConfigured: Bool {
        switch settings.settings.suggestionBackend {
        case .local: return localEngineUsable
        case .external:
            return externalEngineProvider != nil
                && !settings.settings.externalLLMEndpoint.isEmpty
                && !settings.settings.externalLLMModel.isEmpty
        }
    }

    // MARK: - Lifecycle

    public func activate() {
        hotkey.update(HotkeyConfig(settings.settings.discussionHotkey))
        hotkey.onStart = { [weak self] in
            Task { @MainActor in self?.handleHotkey() }
        }
        hotkey.onStop = { [weak self] in
            Task { @MainActor in self?.handleHotkey() }
        }
        if settings.settings.discussionEnabled { hotkey.start() }
    }

    public func deactivate() {
        hotkey.stop()
        if session.state != .idle { cancel() }
    }

    // MARK: - Key routing

    /// The discussion key is state-dependent in-session (see class comment).
    public func handleHotkey() {
        switch session.state {
        case .idle:
            begin()
        case .presenting:
            skipSpeech()
        case .awaitingUser where micMode == .ptt:
            pttDown()
        case .listening where micMode == .ptt:
            pttUp()
        default:
            publish()   // bring the overlay forward; no second session
        }
    }

    // MARK: - Session begin / teardown

    public func begin() {
        guard session.state == .idle else { return }
        guard settings.settings.discussionEnabled else { return }
        lastError = nil
        guard engineConfigured else {
            lastError = "No dialogue engine is available. Enable the on-device model or configure an endpoint."
            return
        }
        // The mic must be free: mid-utterance dictation keeps priority.
        guard !dictation.phase.isActive else { return }
        guard let target = targetProvider(),
              target.pid != ProcessInfo.processInfo.processIdentifier else { return }   // never discuss into Bark itself

        // Hard mic ownership: suspend hands-free for the session (resumed on
        // teardown), then take the lease so neither dictation path can start.
        handsFreeWasActive = dictation.handsFreeActive
        if handsFreeWasActive { dictation.stopHandsFree() }
        dictation.micLeaseHeld = true

        capturedTarget = target
        sessionToken += 1
        let token = sessionToken
        session.handle(.begin)
        publish()
        if settings.settings.suggestionBackend == .local { dictation.prepareLLM() }   // load overlaps capture

        flowTask = Task { [weak self] in await self?.runCaptureAndOpen(target: target, token: token) }
    }

    private func runCaptureAndOpen(target: InjectionTarget, token: Int) async {
        // Warm STT while capture runs so the first turn starts instantly.
        try? await stt.prepare(locale: settings.settings.localeID)
        guard token == sessionToken else { return }
        do {
            let captured = try await capture.capture(target: target)
            guard token == sessionToken, session.state == .capturing else { return }
            context = captured
            session.handle(.captureSucceeded(hasContext: true))
        } catch ContextCaptureError.secureField {
            guard token == sessionToken, session.state == .capturing else { return }
            session.handle(.captureRefusedSecure)   // FR-013
            lastError = "Bark won't run a discussion over a password field."
            teardown()
            return
        } catch {
            guard token == sessionToken, session.state == .capturing else { return }
            context = nil   // contextless degrade — visible in the overlay
            session.handle(.captureSucceeded(hasContext: false))
        }
        publish()
        await engineTurn(token: token)
    }

    /// Wipes everything a session held (FR-010) and returns mic ownership.
    private func teardown() {
        sessionToken += 1
        flowTask?.cancel(); flowTask = nil
        turnTask?.cancel(); turnTask = nil
        speakTask?.cancel(); speakTask = nil
        injectTask?.cancel(); injectTask = nil
        stopPTTAudio()
        synthesizer?.stop()
        Task { await stt.cancel() }
        context = nil
        capturedTarget = nil
        finalSegments = []; volatileTail = ""
        session = DiscussionSession()
        dictation.micLeaseHeld = false
        if handsFreeWasActive {
            handsFreeWasActive = false
            dictation.startHandsFree()
        }
        publish()
    }

    // MARK: - User actions (overlay buttons / keys)

    public func cancel() {
        guard session.state != .idle else { return }
        session.handle(.cancelRequested)
        publish()
        teardown()
    }

    public func done() {
        stopListeningIfNeeded()
        let token = sessionToken
        session.handle(.doneRequested)
        publish()
        if session.state == .synthesizing {
            turnTask = Task { [weak self] in await self?.runSynthesis(token: token) }
        }
    }

    public func retryTurn() {
        let token = sessionToken
        session.handle(.retryTurn)
        publish()
        if session.state == .thinking {
            turnTask = Task { [weak self] in await self?.engineTurn(token: token) }
        }
    }

    public func retrySynthesis() {
        let token = sessionToken
        session.handle(.retrySynthesis)
        publish()
        if session.state == .synthesizing {
            turnTask = Task { [weak self] in await self?.runSynthesis(token: token) }
        }
    }

    public func resume() {
        session.handle(.resumeRequested)
        publish()
        armMicIfNeeded()
    }

    public func confirm() {
        guard session.state == .previewing, let prompt = session.synthesizedPrompt else { return }
        let token = sessionToken
        session.handle(.confirmRequested)
        publish()
        injectTask = Task { [weak self] in await self?.inject(prompt, token: token) }
    }

    /// Re-run capture against the session target, replacing the snapshot on
    /// success and keeping the previous one on failure (US3).
    public func recapture() {
        guard let target = capturedTarget,
              session.state == .awaitingUser || session.state == .presenting || session.state == .turnFailed
        else { return }
        let token = sessionToken
        Task { [weak self] in
            guard let self else { return }
            if let fresh = try? await self.capture.capture(target: target) {
                guard token == self.sessionToken else { return }
                self.context = fresh
            } else {
                guard token == self.sessionToken else { return }
                self.lastError = "Couldn't re-read the window — keeping the previous context."
            }
            self.publish()
        }
    }

    /// Copies the previewed prompt without injecting (used after an injection
    /// refusal, e.g. the target app changed or quit).
    public func copyPrompt() {
        guard let prompt = session.synthesizedPrompt, let target = capturedTarget else { return }
        let token = sessionToken
        Task { [weak self] in
            guard let self else { return }
            let plan = InjectionPlan(target: target, strategy: .copyOnly, stripTrailingNewlines: true)
            do { try await self.clipboardInjector.inject(prompt, plan: plan) }
            catch { guard token == self.sessionToken else { return }
                    self.lastError = "Couldn't copy the prompt." }
        }
    }

    /// Offers the transcript when synthesis has failed twice (SC-004: the
    /// discussion is never silently lost).
    public func copyTranscript() {
        guard let target = capturedTarget, !session.transcript.isEmpty else { return }
        let token = sessionToken
        let text = session.transcript
            .map { ($0.role == .user ? "You: " : "AI: ") + $0.text }
            .joined(separator: "\n")
        Task { [weak self] in
            guard let self else { return }
            let plan = InjectionPlan(target: target, strategy: .copyOnly, stripTrailingNewlines: true)
            do { try await self.clipboardInjector.inject(text, plan: plan) }
            catch { guard token == self.sessionToken else { return }
                    self.lastError = "Couldn't copy the transcript." }
        }
    }

    // MARK: - Engine loop

    private func activeEngine() -> DialogueEngine? {
        switch settings.settings.suggestionBackend {
        case .local:
            return localEngineUsable ? localEngine : nil
        case .external:
            guard let provider = externalEngineProvider else { return nil }
            let s = settings.settings
            guard !s.externalLLMEndpoint.isEmpty, !s.externalLLMModel.isEmpty else { return nil }
            return provider(s.externalLLMEndpoint, s.externalLLMModel,
                            secretStore.read(account: SuggestionController.apiKeyAccount))
        }
    }

    private func engineTurn(token: Int) async {
        guard token == sessionToken, session.state == .thinking else { return }
        guard let engine = activeEngine() else {
            session.handle(.engineFailed)
            lastError = "No dialogue engine is available."
            publish()
            return
        }
        let system = DialoguePromptBuilder.dialogueSystem(context: context)
        let turns = DialoguePromptBuilder.fencedTurns(session.transcript)
        do {
            let raw = try await raced(seconds: replyDeadline) {
                try await engine.reply(system: system, turns: turns)
            }
            guard token == sessionToken, session.state == .thinking else { return }
            let reply = DialogueReplyParser.parse(raw)
            session.handle(.replyArrived(reply))
            publish()
            if session.state == .synthesizing {
                await runSynthesis(token: token)
            } else if session.state == .presenting {
                present(reply, token: token)
            }
        } catch {
            guard token == sessionToken, session.state == .thinking else { return }
            session.handle(.engineFailed)
            lastError = Self.engineMessage(error)
            publish()
        }
    }

    /// Show the reply; speak it when TTS is on. `presentationFinished` fires
    /// only when speech is done (or immediately without TTS) — that IS the
    /// half-duplex gate.
    private func present(_ reply: DialogueReply, token: Int) {
        if ttsEnabled, let synthesizer {
            speakTask = Task { [weak self] in
                await synthesizer.speak(reply.text)
                guard let self, token == self.sessionToken else { return }
                self.finishPresentation()
            }
        } else {
            finishPresentation()
        }
    }

    private func finishPresentation() {
        guard session.state == .presenting else { return }
        session.handle(.presentationFinished)
        publish()
        armMicIfNeeded()
    }

    /// Key tap during TTS playback: stop speech now and open the turn (US2).
    private func skipSpeech() {
        if ttsEnabled, synthesizer != nil {
            synthesizer?.stop()   // the pending speak() returns → finishPresentation
        } else {
            finishPresentation()
        }
    }

    private func runSynthesis(token: Int) async {
        guard token == sessionToken, session.state == .synthesizing else { return }
        guard let engine = activeEngine() else {
            session.handle(.synthesisFailed)
            lastError = "No dialogue engine is available."
            publish()
            return
        }
        let system = DialoguePromptBuilder.synthesisSystem(context: context)
        let turns = DialoguePromptBuilder.fencedTurns(session.transcript)
        do {
            var prompt = try await raced(seconds: synthesisDeadline) {
                try await engine.synthesize(system: system, turns: turns)
            }
            guard token == sessionToken, session.state == .synthesizing else { return }
            prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if prompt.count > Self.synthesizedPromptCharBound {
                prompt = String(prompt.prefix(Self.synthesizedPromptCharBound))
            }
            if prompt.isEmpty {
                session.handle(.synthesisFailed)
                lastError = "The engine produced an empty draft."
            } else {
                session.handle(.synthesisSucceeded(prompt))
            }
        } catch {
            guard token == sessionToken, session.state == .synthesizing else { return }
            session.handle(.synthesisFailed)
            lastError = Self.engineMessage(error)
        }
        publish()
    }

    /// Structured deadline race (the 016 lesson: `withThrowingDeadline` runs
    /// its body in an unstructured Task that cancellation can't reach).
    private nonisolated func raced<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw DialogueError.deadlineExceeded
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Turn capture (mic)

    private func armMicIfNeeded() {
        guard session.state == .awaitingUser else { return }
        guard micMode == .handsFree else { return }   // PTT waits for the key
        let token = sessionToken
        turnTask = Task { [weak self] in await self?.runVADTurn(token: token) }
    }

    private func stopListeningIfNeeded() {
        guard session.state == .listening || session.state == .awaitingUser else { return }
        turnTask?.cancel(); turnTask = nil
        stopPTTAudio()
        Task { await stt.cancel() }
        finalSegments = []; volatileTail = ""
        if session.state == .listening {
            // Unwind the open turn so Done is legal from mid-listen: an
            // abandoned turn is an empty turn.
            session.handle(.userTurnEnded)
            session.handle(.transcriptFinal(""))
        }
    }

    /// One VAD-gated utterance per arm cycle: mirror of `runHandsFree`, but
    /// the product is a transcript event — no cleanup, no injection.
    private func runVADTurn(token: Int) async {
        let engine = audioFactory()
        let stream: AsyncStream<AudioFrames>
        do { stream = try engine.start() }
        catch {
            guard token == sessionToken else { return }
            lastError = "Couldn't open the microphone."
            return
        }
        defer { engine.stop() }

        var vad = VoiceActivityDetector(config: VADConfig(sensitivity: settings.settings.vadSensitivity))
        var capturing = false
        var preroll: [AudioFrames] = []
        let prerollMax = 3   // ~300 ms onset protection
        var capturedFrames = 0
        let maxUtteranceFrames = 300   // ~30 s cap

        for await frames in stream {
            guard token == sessionToken, !Task.isCancelled else { return }
            let event = vad.process(frames)

            if !capturing {
                preroll.append(frames)
                if preroll.count > prerollMax { preroll.removeFirst() }
                guard event == .speechStarted else { continue }
                guard await beginSTTTurn(token: token) else { return }
                for f in preroll { await stt.feed(f) }
                preroll.removeAll()
                capturing = true
                capturedFrames = 0
            } else {
                await stt.feed(frames)
                capturedFrames += 1
                guard event == .speechEnded || capturedFrames >= maxUtteranceFrames else { continue }
                await endSTTTurn(token: token)
                // Non-empty → thinking (engine turn runs); empty → keep this
                // same stream open and listen for the next utterance.
                guard token == sessionToken else { return }
                if session.state == .awaitingUser {
                    capturing = false
                    vad.reset()
                    continue
                }
                return
            }
        }
    }

    // PTT: the discussion key toggles the turn open/closed.

    private func pttDown() {
        guard session.state == .awaitingUser else { return }
        let token = sessionToken
        turnTask = Task { [weak self] in
            guard let self else { return }
            guard await self.beginSTTTurn(token: token) else { return }
            let engine = self.audioFactory()
            self.pttAudio = engine
            guard let stream = try? engine.start() else {
                self.lastError = "Couldn't open the microphone."
                await self.endSTTTurn(token: token)
                return
            }
            self.pttFeedTask = Task { [weak self] in
                for await frames in stream {
                    guard let self, token == self.sessionToken else { return }
                    await self.stt.feed(frames)
                }
            }
        }
    }

    private func pttUp() {
        guard session.state == .listening else { return }
        let token = sessionToken
        turnTask = Task { [weak self] in
            guard let self else { return }
            self.stopPTTAudio()
            await self.endSTTTurn(token: token)
        }
    }

    private func stopPTTAudio() {
        pttFeedTask?.cancel(); pttFeedTask = nil
        pttAudio?.stop(); pttAudio = nil
    }

    /// Starts an STT stream + consumer and moves the session to `listening`.
    private func beginSTTTurn(token: Int) async -> Bool {
        guard token == sessionToken, session.state == .awaitingUser else { return false }
        finalSegments = []; volatileTail = ""
        do {
            let results = try await stt.beginStream()
            guard token == sessionToken else { await stt.cancel(); return false }
            session.handle(.userTurnBegan)
            publish()
            sttConsumer = Task { @MainActor [weak self] in
                do {
                    for try await r in results {
                        guard let self, token == self.sessionToken else { return }
                        if r.isFinal {
                            if !r.text.isEmpty { self.finalSegments.append(r.text) }
                            self.volatileTail = ""
                        } else {
                            self.volatileTail = r.text
                        }
                    }
                } catch {}
            }
            return true
        } catch {
            guard token == sessionToken else { return false }
            lastError = "Couldn't start the speech engine."
            return false
        }
    }

    /// Finalizes the STT stream and dispatches the turn's transcript.
    private func endSTTTurn(token: Int) async {
        guard token == sessionToken, session.state == .listening else { return }
        session.handle(.userTurnEnded)
        publish()
        do {
            try await raced(seconds: sttFinalizeDeadline) { [stt] in try await stt.finishStream() }
        } catch {
            await stt.cancel()
        }
        await sttConsumer?.value
        sttConsumer = nil
        guard token == sessionToken, session.state == .transcribing else { return }
        let transcript = (finalSegments.joined(separator: " ") + " " + volatileTail)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        finalSegments = []; volatileTail = ""
        session.handle(.transcriptFinal(transcript))
        publish()
        if session.state == .thinking {
            await engineTurn(token: token)
        }
        // Empty turn: state is back to awaitingUser. In VAD mode the running
        // loop keeps listening; in PTT mode the next key tap opens a turn.
    }

    // MARK: - Injection handoff (Confirm)

    /// Copies the 015 sequence exactly; the preflight inside every injector
    /// re-verifies the frontmost PID and refuses secure fields. No
    /// `ReturnKeySynthesizing` exists on this path (FR-007).
    private func inject(_ prompt: String, token: Int) async {
        try? await Task.sleep(for: settleDelay)   // let focus return to the target
        guard token == sessionToken, session.state == .injecting,
              let target = capturedTarget else { return }
        let sanitized = TextSanitizer.sanitize(
            prompt,
            options: .init(allowNewlines: !target.isTerminal, stripTrailingNewlines: true)
        )
        guard !sanitized.isEmpty else {
            session.handle(.injectionFailed)
            lastError = "Nothing to insert after sanitizing the draft."
            publish()
            return
        }
        let strategy = InjectionRouter.strategy(
            routing: settings.settings.outputRouting,
            isTerminal: target.isTerminal
        )
        let plan = InjectionPlan(target: target, strategy: strategy, stripTrailingNewlines: true)
        do {
            try await injector(for: strategy).inject(sanitized, plan: plan)
            guard token == sessionToken else { return }
            session.handle(.injectionSucceeded)
            publish()
            teardown()
        } catch {
            guard token == sessionToken else { return }
            session.handle(.injectionFailed)
            lastError = Self.injectionMessage(error)
            publish()
        }
    }

    private func injector(for strategy: InjectionStrategy) -> TextInjector {
        switch strategy {
        case .copyOnly: return clipboardInjector
        case .keystroke: return keystrokeInjector
        case .paste: return pasteInjector
        }
    }

    // MARK: - Messages

    private func publish() {
        onSessionChange?(session)
    }

    static func engineMessage(_ error: Error) -> String {
        switch error {
        case DialogueError.deadlineExceeded:
            return "The engine took too long — retry, or press Done to draft from what we have."
        case DialogueError.engineUnavailable:
            return "No dialogue engine is available."
        case DialogueError.transport(let detail):
            return "The endpoint failed (\(detail)) — retry, or press Done."
        case DialogueError.badResponse:
            return "The engine returned an unusable reply — retry, or press Done."
        default:
            return "The engine failed — retry, or press Done."
        }
    }

    static func injectionMessage(_ error: Error) -> String {
        switch error {
        case InjectionError.focusChanged:
            return "The focused app changed — switch back and Confirm again, or copy the prompt."
        case InjectionError.secureFieldBlocked:
            return "A secure field has focus — Bark won't type there. Copy the prompt instead."
        case InjectionError.accessibilityDenied:
            return "Accessibility permission is required to insert text. Copy the prompt instead."
        default:
            return "Couldn't insert the prompt — copy it instead."
        }
    }
}
