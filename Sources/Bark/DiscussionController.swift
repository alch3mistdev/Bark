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
    private let captureDeadline: Double
    private let settleDelay: Duration

    private var capturedTarget: InjectionTarget?
    private var context: CapturedContext?
    private var handsFreeWasActive = false
    /// Invalidates every in-flight task of a torn-down session (015's
    /// `passToken` pattern — callees don't all honor cancellation).
    private var sessionToken = 0
    /// Single-owner mic arming (ADV-001): every arm bumps this; a VAD loop
    /// whose generation is stale must stop its engine and exit — otherwise a
    /// synchronous present→arm chain leaves the OLD loop alive alongside the
    /// new one, one more per turn.
    private var micGeneration = 0
    /// Guards `presenting` exits (ADV-003): a stale speak-completion may only
    /// dispatch `presentationFinished` for its own presentation.
    private var presentGeneration = 0
    /// Set synchronously on the PTT key tap (ADV-002): the state machine only
    /// flips to `listening` after an await, so state alone can't stop a
    /// double-tap from spawning two capture engines and orphaning one.
    private var pttTurnActive = false
    private var flowTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var injectTask: Task<Void, Never>?
    /// Pending fire-and-forget `stt.cancel()` (ADV-012): awaited before the
    /// next `beginStream` so a delayed cleanup can't kill the new turn.
    private var sttCleanup: Task<Void, Never>?

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
        captureDeadline: Double = 15,
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
        self.captureDeadline = captureDeadline
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

    /// "" = auto (best installed tier for the user's language).
    public var voiceID: String {
        get { settings.settings.discussionVoiceID }
        set { settings.update { $0.discussionVoiceID = newValue } }
    }

    public var speechRate: Float {
        get { settings.settings.discussionSpeechRate }
        set { settings.update { $0.discussionSpeechRate = newValue } }
    }

    /// Voices offered in the picker, best tier first (novelty/Eloquence last).
    public var voiceOptions: [VoiceOption] {
        VoiceSelector.options(from: synthesizer?.availableVoices ?? [],
                              language: settings.settings.localeID)
    }

    /// The voice that would actually speak right now — what the UI labels as
    /// the resolved "Automatic" choice.
    public var resolvedVoice: VoiceOption? {
        VoiceSelector.best(from: synthesizer?.availableVoices ?? [],
                           language: settings.settings.localeID,
                           preferred: settings.settings.discussionVoiceID)
    }

    /// True when this Mac has NO Enhanced or Premium voice for the user's
    /// language — the stock state, and the single biggest cause of "the TTS
    /// sounds terrible". Drives the download hint.
    public var shouldSuggestVoiceDownload: Bool {
        !VoiceSelector.hasBetterTierAvailable(than: .basic,
                                              from: synthesizer?.availableVoices ?? [],
                                              language: settings.settings.localeID)
    }

    /// Speak a sample line so the user can audition a voice from Settings.
    /// Refused while a reply is being spoken, so auditioning can never overlap
    /// session speech (and so it can't disturb the half-duplex gate).
    public func previewVoice() {
        guard let synthesizer, speakTask == nil else { return }
        let config = voiceConfig()
        Task { await synthesizer.speak("Here's how this voice sounds. What are you trying to write?",
                                       voice: config) }
    }

    private func voiceConfig() -> SpeechVoiceConfig {
        SpeechVoiceConfig(voiceIdentifier: resolvedVoice?.identifier,
                          rate: settings.settings.discussionSpeechRate)
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
        case .capturing:
            // Capture/prepare can stall on a hung app or a model load; the
            // panel isn't key yet so Esc can't reach us — F7 is the escape
            // hatch (ADV-005).
            cancel()
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
        // STT prepare + capture, under one deadline: either can stall (model
        // download, AX IPC against a hung app) and `capturing` would otherwise
        // hold the mic lease with no automatic way out (ADV-005).
        do {
            let locale = settings.settings.localeID
            let captured = try await raced(seconds: captureDeadline) { [stt, capture] in
                try? await stt.prepare(locale: locale)
                return try await capture.capture(target: target)
            }
            guard token == sessionToken, session.state == .capturing else { return }
            context = captured
            session.handle(.captureSucceeded(hasContext: true))
        } catch ContextCaptureError.secureField {
            guard token == sessionToken, session.state == .capturing else { return }
            session.handle(.captureRefusedSecure)   // FR-013
            lastError = "Bark won't run a discussion over a password field."
            teardown()
            return
        } catch DialogueError.deadlineExceeded {
            guard token == sessionToken, session.state == .capturing else { return }
            session.handle(.cancelRequested)
            lastError = "Couldn't read the window or prepare speech in time — session cancelled."
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
        micGeneration += 1
        presentGeneration += 1
        flowTask?.cancel(); flowTask = nil
        turnTask?.cancel(); turnTask = nil
        speakTask?.cancel(); speakTask = nil
        injectTask?.cancel(); injectTask = nil
        stopPTTAudio()
        pttTurnActive = false
        synthesizer?.stop()
        scheduleSTTCleanup()
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
        stopSpeakingIfNeeded()
        session.handle(.cancelRequested)
        publish()
        teardown()
    }

    public func done() {
        stopListeningIfNeeded()
        stopSpeakingIfNeeded()   // leaving `presenting` must silence TTS (ADV-003)
        let token = sessionToken
        let before = session.state
        session.handle(.doneRequested)
        publish()
        // Spawn only on an actual transition — a no-op event (e.g. D pressed
        // while already synthesizing) must not double the engine call (ADV-014).
        if session.state == .synthesizing, before != .synthesizing {
            turnTask = Task { [weak self] in await self?.runSynthesis(token: token) }
        }
    }

    public func retryTurn() {
        let token = sessionToken
        let before = session.state
        session.handle(.retryTurn)
        publish()
        if session.state == .thinking, before != .thinking {
            turnTask = Task { [weak self] in await self?.engineTurn(token: token) }
        }
    }

    public func retrySynthesis() {
        let token = sessionToken
        let before = session.state
        session.handle(.retrySynthesis)
        publish()
        if session.state == .synthesizing, before != .synthesizing {
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
    /// success and keeping the previous one on failure (US3). A secure-field
    /// refusal is surfaced as such — the same policy begin() enforces — not
    /// blurred into a generic re-read failure (ADV-015).
    public func recapture() {
        guard let target = capturedTarget,
              session.state == .awaitingUser || session.state == .presenting || session.state == .turnFailed
        else { return }
        let token = sessionToken
        Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await self.capture.capture(target: target)
                guard token == self.sessionToken else { return }
                self.context = fresh
            } catch ContextCaptureError.secureField {
                guard token == self.sessionToken else { return }
                self.lastError = "The window now has a secure field focused — Bark won't re-read it; keeping the previous context."
            } catch {
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
            let parsed = DialogueReplyParser.parse(raw)
            // Assistant turns are replayed unfenced in later prompts, so a
            // model-echoed fence tag must be neutralized BEFORE it enters the
            // transcript — otherwise one echo becomes a persistent
            // assistant-role injection foothold (ADV-008).
            let reply = DialogueReply(text: DialoguePromptBuilder.neutralize(parsed.text),
                                      isReadyToSynthesize: parsed.isReadyToSynthesize)
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
    /// half-duplex gate. Each presentation gets a generation so a stale speak
    /// completion (released by a later stop() or a follow-up speak()) can
    /// never finish a DIFFERENT presentation (ADV-003 path B).
    private func present(_ reply: DialogueReply, token: Int) {
        if ttsEnabled, let synthesizer {
            presentGeneration += 1
            let generation = presentGeneration
            let config = voiceConfig()
            speakTask = Task { [weak self] in
                await synthesizer.speak(reply.text, voice: config)
                guard let self, token == self.sessionToken,
                      generation == self.presentGeneration else { return }
                self.speakTask = nil
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
    /// `speakTask != nil` (not the current toggle value) decides whether audio
    /// might be playing — toggling TTS off mid-playback must still stop it
    /// (ADV-003 path C).
    private func skipSpeech() {
        if speakTask != nil {
            synthesizer?.stop()   // the pending speak() returns → finishPresentation
        } else {
            finishPresentation()
        }
    }

    /// Silence any exit from `presenting` that isn't `presentationFinished`:
    /// stop playback and invalidate the pending speak-completion so it cannot
    /// release the mic gate for a state we've already left (ADV-003).
    private func stopSpeakingIfNeeded() {
        guard speakTask != nil else { return }
        presentGeneration += 1
        synthesizer?.stop()
        speakTask = nil
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

    /// Single arm point (ADV-001): bumps the mic generation and replaces the
    /// turn loop, so at most ONE loop is ever live — a stale loop notices its
    /// generation and stops its own engine.
    private func armMicIfNeeded() {
        guard session.state == .awaitingUser else { return }
        guard micMode == .handsFree else { return }   // PTT waits for the key
        turnTask?.cancel()
        micGeneration += 1
        let token = sessionToken
        let generation = micGeneration
        turnTask = Task { [weak self] in await self?.runVADTurn(token: token, generation: generation) }
    }

    private func stopListeningIfNeeded() {
        guard session.state == .listening || session.state == .awaitingUser else { return }
        micGeneration += 1   // any live VAD loop is now stale
        turnTask?.cancel(); turnTask = nil
        stopPTTAudio()
        pttTurnActive = false
        scheduleSTTCleanup()
        finalSegments = []; volatileTail = ""
        if session.state == .listening {
            // Unwind the open turn so Done is legal from mid-listen: an
            // abandoned turn is an empty turn.
            session.handle(.userTurnEnded)
            session.handle(.transcriptFinal(""))
        }
    }

    /// Fire `stt.cancel()` without blocking the caller, but keep the handle so
    /// the next `beginStream` can await it — an unordered late cancel could
    /// otherwise tear down the replacement turn's stream (ADV-012).
    private func scheduleSTTCleanup() {
        let previous = sttCleanup
        sttCleanup = Task { [stt] in
            await previous?.value
            await stt.cancel()
        }
    }

    /// One VAD-gated utterance per arm cycle: mirror of `runHandsFree`, but
    /// the product is a transcript event — no cleanup, no injection. The
    /// audio engine is stopped BEFORE transcription/generation run, so the
    /// mic is closed (at the device level, not just by state) outside the
    /// mic-legal states (ADV-004); the turn's aftermath is dispatched from
    /// outside the loop and this task never survives past it (ADV-001).
    private func runVADTurn(token: Int, generation: Int) async {
        let engine = audioFactory()
        let stream: AsyncStream<AudioFrames>
        do { stream = try engine.start() }
        catch {
            guard token == sessionToken else { return }
            lastError = "Couldn't open the microphone."
            return
        }

        var vad = VoiceActivityDetector(config: VADConfig(sensitivity: settings.settings.vadSensitivity))
        var capturing = false
        var preroll: [AudioFrames] = []
        let prerollMax = 3   // ~300 ms onset protection
        var capturedFrames = 0
        let maxUtteranceFrames = 300   // ~30 s cap

        for await frames in stream {
            guard token == sessionToken, generation == micGeneration, !Task.isCancelled else {
                engine.stop()
                return
            }
            let event = vad.process(frames)

            if !capturing {
                preroll.append(frames)
                if preroll.count > prerollMax { preroll.removeFirst() }
                guard event == .speechStarted else { continue }
                guard await beginSTTTurn(token: token) else { engine.stop(); return }
                guard token == sessionToken, generation == micGeneration else { engine.stop(); return }
                for f in preroll { await stt.feed(f) }
                preroll.removeAll()
                capturing = true
                capturedFrames = 0
            } else {
                await stt.feed(frames)
                capturedFrames += 1
                guard event == .speechEnded || capturedFrames >= maxUtteranceFrames else { continue }
                break   // utterance complete — close the mic before anything else
            }
        }
        engine.stop()
        guard capturing, token == sessionToken, generation == micGeneration else { return }
        await finishTurn(token: token)
        // finishTurn re-arms (fresh loop, fresh generation) after an empty
        // turn or dispatches the engine turn; either way THIS loop is done.
    }

    // PTT: the discussion key toggles the turn open/closed.

    private func pttDown() {
        guard session.state == .awaitingUser else { return }
        // Synchronous latch (ADV-002): the state flips to `listening` only
        // after beginStream's await, so a double-tap would otherwise spawn a
        // second engine and orphan the first — a permanently hot mic.
        guard !pttTurnActive else { return }
        pttTurnActive = true
        let token = sessionToken
        turnTask = Task { [weak self] in
            guard let self else { return }
            guard await self.beginSTTTurn(token: token) else {
                if token == self.sessionToken { self.pttTurnActive = false }
                return
            }
            guard token == self.sessionToken, self.session.state == .listening else {
                if token == self.sessionToken { self.pttTurnActive = false }
                return
            }
            let engine = self.audioFactory()
            self.pttAudio = engine
            guard let stream = try? engine.start() else {
                self.lastError = "Couldn't open the microphone."
                await self.endPTTTurn(token: token)
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
        guard session.state == .listening, pttTurnActive else { return }
        let token = sessionToken
        turnTask = Task { [weak self] in await self?.endPTTTurn(token: token) }
    }

    private func endPTTTurn(token: Int) async {
        stopPTTAudio()
        await finishTurn(token: token)
        if token == sessionToken { pttTurnActive = false }
    }

    private func stopPTTAudio() {
        pttFeedTask?.cancel(); pttFeedTask = nil
        pttAudio?.stop(); pttAudio = nil
    }

    /// Starts an STT stream + consumer and moves the session to `listening`.
    private func beginSTTTurn(token: Int) async -> Bool {
        guard token == sessionToken, session.state == .awaitingUser else { return false }
        await sttCleanup?.value   // a late cancel must not kill this stream (ADV-012)
        guard token == sessionToken, session.state == .awaitingUser else { return false }
        finalSegments = []; volatileTail = ""
        do {
            let results = try await stt.beginStream()
            guard token == sessionToken, session.state == .awaitingUser else {
                scheduleSTTCleanup()
                return false
            }
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

    /// Finalizes the STT stream, dispatches the turn's transcript, and drives
    /// the aftermath: engine turn on a non-empty turn, re-arm on an empty one.
    private func finishTurn(token: Int) async {
        guard token == sessionToken, session.state == .listening else { return }
        session.handle(.userTurnEnded)
        publish()
        // Unstructured deadline ON PURPOSE (ADV-011): a wedged SpeechAnalyzer
        // finalize ignores cancellation, and a structured race would join the
        // wedged child and freeze this turn forever — the exact failure
        // 0f9a9a3 fixed for dictation. Accepting the leaked task is the fix.
        do {
            try await withThrowingDeadline(seconds: sttFinalizeDeadline) { [stt] in try await stt.finishStream() }
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
        } else if session.state == .awaitingUser {
            armMicIfNeeded()   // empty turn — fresh loop in VAD mode; PTT waits for the key
        }
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
