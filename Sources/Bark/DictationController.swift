import Foundation
import Observation
import BarkCore
import BarkEngines

/// Lifecycle of the optional on-device rewrite model (for the Settings UI).
public enum LLMStatus: Equatable, Sendable {
    case unavailable          // engine not compiled into this build
    case notLoaded            // engine present; model not downloaded/loaded yet
    case downloading(Double)  // 0...1
    case ready
    case failed(String)
}

/// The conductor. Wires hotkey → audio capture → STT → cleanup → injection,
/// driving the pure `DictationStateMachine`. Lives on the main actor; the heavy
/// work (capture, STT, LLM) runs in engines off the main thread.
@MainActor
@Observable
public final class DictationController {
    // Observable UI state
    public private(set) var phase: DictationPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    public private(set) var liveText: String = ""
    public private(set) var lastError: String?
    public private(set) var lastResult: String?
    public private(set) var isModelReady = false
    public private(set) var llmStatus: LLMStatus = .unavailable
    public private(set) var handsFreeActive = false
    public private(set) var isReinserting = false   // serializes one-click re-insert (Codex)
    public private(set) var inputLevel: Float = 0    // 0...1 smoothed mic level for the HUD meter

    /// Side-channel callbacks wired by the app layer (AppKit windows/HUD).
    public var onPhaseChange: (@MainActor (DictationPhase) -> Void)?
    public var onOpenSettings: (@MainActor () -> Void)?
    public var onHandsFreeChange: (@MainActor (Bool) -> Void)?

    // Collaborators
    public let settings: SettingsStore
    public let permissions: PermissionsCoordinator
    private let hotkey: HotkeyManager
    private let handsFreeHotkey: HotkeyManager
    private let audioFactory: @Sendable () -> AudioCapturing
    private var stt: STTEngine
    private let basicCleaner = BasicTextCleaner()
    private let llmCleaner: TextCleaner?
    private let pasteInjector: TextInjector
    private let keystrokeInjector: TextInjector
    private let clipboardInjector: TextInjector
    private let history: HistoryStore?
    private let cleanupDeadline: Double
    private let targetProvider: @MainActor () -> InjectionTarget?

    private var machine = DictationStateMachine()
    private var audio: AudioCapturing?
    private var feedTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var finalSegments: [String] = []
    private var volatileTail = ""
    private var capturedTarget: InjectionTarget?
    private var reinsertTarget: InjectionTarget?   // frontmost app snapshotted when the re-insert UI opened
    private var prepareToken = 0
    private var llmTask: Task<Void, Never>?
    private var handsFreeTask: Task<Void, Never>?
    private var handsFreeAudio: AudioCapturing?

    public init(
        settings: SettingsStore,
        permissions: PermissionsCoordinator,
        hotkey: HotkeyManager,
        stt: STTEngine,
        handsFreeHotkey: HotkeyManager = HotkeyManager(),
        llmCleaner: TextCleaner?,
        history: HistoryStore? = nil,
        audioFactory: @escaping @Sendable () -> AudioCapturing = { AudioCaptureEngine() },
        pasteInjector: TextInjector = PasteboardInjector(),
        keystrokeInjector: TextInjector = KeystrokeInjector(),
        clipboardInjector: TextInjector = ClipboardInjector(),
        cleanupDeadline: Double = 8,
        targetProvider: @escaping @MainActor () -> InjectionTarget? = { FocusProbe.currentTarget() }
    ) {
        self.settings = settings
        self.permissions = permissions
        self.hotkey = hotkey
        self.handsFreeHotkey = handsFreeHotkey
        self.stt = stt
        self.llmCleaner = llmCleaner
        self.history = history
        self.audioFactory = audioFactory
        self.pasteInjector = pasteInjector
        self.keystrokeInjector = keystrokeInjector
        self.clipboardInjector = clipboardInjector
        self.cleanupDeadline = cleanupDeadline
        self.targetProvider = targetProvider
        self.llmStatus = (llmCleaner != nil) ? .notLoaded : .unavailable
    }

    public var llmAvailable: Bool { llmCleaner != nil }

    // MARK: - Settings-derived state (UI binds here; writes persist)

    public var modes: [Mode] { Mode.builtInModes + settings.settings.customModes }

    public var selectedModeID: String {
        get { settings.settings.selectedModeID }
        set { settings.update { $0.selectedModeID = newValue } }
    }

    public var currentMode: Mode { modes.first { $0.id == selectedModeID } ?? .clean }

    /// Mode for the current dictation: per-app mapping (resolved from the
    /// start-time target) if present, else the manual selection.
    private func effectiveMode() -> Mode {
        let id = AppModeResolver.modeID(forBundleID: capturedTarget?.bundleID,
                                        map: settings.settings.appModeMap,
                                        availableModeIDs: Set(modes.map(\.id)),
                                        fallback: selectedModeID)
        return modes.first { $0.id == id } ?? .clean
    }

    public var appModeMap: [String: String] { settings.settings.appModeMap }

    public func setAppMode(bundleID: String, modeID: String?) {
        guard !bundleID.isEmpty else { return }
        settings.update { $0.appModeMap[bundleID] = modeID }
    }

    public var hotkeySetting: HotkeySetting {
        get { settings.settings.hotkey }
        set {
            guard newValue != settings.settings.handsFreeHotkey else {   // no shared binding (ADV-002)
                lastError = "That key is already the hands-free hotkey."
                return
            }
            // Rebinding mid-session would strand a live session on the old key (Codex).
            if machine.isActive { cancelDictation() }
            settings.update { $0.hotkey = newValue }
            hotkey.update(HotkeyConfig(newValue))
        }
    }

    public func upsertMode(_ mode: Mode) {
        // A custom id colliding with a built-in would be silently shadowed (ADV-005).
        guard !Mode.builtInModes.contains(where: { $0.id == mode.id }) else { return }
        settings.update { s in
            if let i = s.customModes.firstIndex(where: { $0.id == mode.id }) { s.customModes[i] = mode }
            else { s.customModes.append(mode) }
        }
    }

    public func removeMode(id: String) {
        guard !Mode.builtInModes.contains(where: { $0.id == id }) else { return }
        settings.update { s in
            s.customModes.removeAll { $0.id == id }
            if s.selectedModeID == id { s.selectedModeID = Mode.clean.id }
        }
    }

    public var launchAtLogin: Bool {
        get { settings.settings.launchAtLogin }
        set {
            // Only persist the toggle if the OS actually accepted it; otherwise
            // reconcile to the real SMAppService state (ADV-002).
            do {
                try LoginItemService.setEnabled(newValue)
                settings.update { $0.launchAtLogin = newValue }
            } catch {
                lastError = "Couldn't update launch-at-login (use the installed app)."
                settings.update { $0.launchAtLogin = LoginItemService.isEnabled }
            }
        }
    }

    public var llmEnabled: Bool {
        get { settings.settings.llmEnabled }
        set {
            settings.update { $0.llmEnabled = newValue }
            if newValue {
                prepareLLM()                       // download/warm the model when opted in
            } else {
                llmTask?.cancel(); llmTask = nil    // stop tracking an in-flight download
                if llmEnginePresent { llmStatus = .notLoaded }
            }
        }
    }

    /// True when the LLM engine is compiled into this build (MLX build).
    public var llmEnginePresent: Bool { llmCleaner != nil }

    /// Download (first run) + load the rewrite model, updating `llmStatus`. The
    /// per-utterance deadline never wraps this — it's a separate, observable step.
    public func prepareLLM() {
        guard let llm = llmCleaner else { return }
        switch llmStatus {
        case .downloading, .ready: return
        default: break
        }
        llmStatus = .downloading(0)
        llmTask?.cancel()
        llmTask = Task { [weak self] in
            do {
                try await llm.prepare(progress: { fraction in
                    Task { @MainActor in self?.setDownloadProgress(fraction) }
                })
                guard let self, !Task.isCancelled, self.settings.settings.llmEnabled else { return }
                self.llmStatus = .ready
            } catch {
                guard let self, !Task.isCancelled, self.settings.settings.llmEnabled else { return }
                self.llmStatus = .failed("Download failed: \((error as NSError).localizedDescription)")
            }
        }
    }

    private func setDownloadProgress(_ fraction: Double) {
        // Monotonic: late/out-of-order progress hops can't make the bar regress.
        if case .downloading(let current) = llmStatus {
            llmStatus = .downloading(max(current, fraction))
        }
    }

    public var historyEnabled: Bool {
        get { settings.settings.historyEnabled }
        set {
            settings.update { $0.historyEnabled = newValue }
            // Turning history OFF wipes the stored transcripts + key (ADV-001):
            // "off" must mean "not retained", matching the spec and UI promise.
            if !newValue { Task { await purgeHistory() } }
        }
    }

    public var localeID: String {
        get { settings.settings.localeID }
        set {
            guard newValue != settings.settings.localeID else { return }
            settings.update { $0.localeID = newValue }
            isModelReady = false
            Task { await prepareModel() }
        }
    }

    /// The active STT backend. Setting rebuilds the engine via the factory and
    /// triggers a re-prepare. Refuses to swap mid-dictation (the live session's
    /// analyzer is single-use; see ADV-007 in `SpeechAnalyzerEngine`).
    public var sttBackend: STTBackendID {
        get { settings.settings.sttBackend }
        set {
            guard newValue != settings.settings.sttBackend else { return }
            guard !machine.isActive else {
                lastError = "Stop dictation before changing the speech engine."
                return
            }
            settings.update { $0.sttBackend = newValue }
            let manifest = STTEngineFactory.bundledManifest(for: newValue)
            self.stt = STTEngineFactory.make(
                id: newValue,
                manifest: manifest,
                downloader: ModelDownloader()
            )
            isModelReady = false
            Task { await prepareModel() }
        }
    }

    public func historyRecords() async -> [HistoryRecord] {
        await history?.all() ?? []
    }

    /// Search saved history (case/diacritic-insensitive); empty query → recent. (007)
    public func searchHistory(_ query: String) async -> [HistoryRecord] {
        await history?.search(query) ?? []
    }

    /// Re-use a past dictation by copying it to the clipboard. The safe path from
    /// the Settings window (frontmost), where typing would land in the wrong app.
    /// Marks the payload concealed; never restores the clipboard. (007)
    public func copyToClipboard(_ text: String) async {
        let plan = InjectionPlan(target: InjectionTarget(pid: 0, bundleID: nil), strategy: .copyOnly)
        do {
            try await clipboardInjector.inject(text, plan: plan)
            lastResult = text
            if soundFeedback { Feedback.inserted() }
        } catch {
            lastError = Self.injectionMessage(error)
        }
    }

    /// Snapshot the frontmost (non-Bark) app when the re-insert UI appears, so a
    /// later one-click re-insert targets the app the user was actually in — not
    /// whatever is frontmost after they interact with Bark's menu (Codex/ADV-004).
    /// Bark itself (the popover holding key focus) is never a valid target.
    public func snapshotReinsertTarget() {
        let t = targetProvider()
        reinsertTarget = (t?.pid == ProcessInfo.processInfo.processIdentifier) ? nil : t
    }

    /// Type a past dictation into the app captured by `snapshotReinsertTarget`.
    /// Re-verifies that app is still frontmost immediately before injecting (the
    /// injector's preflight compares the snapshot's pid against the live focus, so
    /// a focus drift to Bark/another app refuses rather than mis-targets). Honours
    /// the secure-field guard and output routing. Serialized so rapid clicks can't
    /// overlap on the shared pasteboard (Codex). No-op while a dictation is active
    /// or another re-insert is in flight. (007 / ADV-004)
    public func reinsert(_ record: HistoryRecord) async {
        guard !phase.isActive, !isReinserting else { return }
        guard let target = reinsertTarget else {
            lastError = Self.injectionMessage(InjectionError.focusChanged); return
        }
        let sanitized = TextSanitizer.sanitize(
            record.output,
            options: .init(allowNewlines: !target.isTerminal, stripTrailingNewlines: true)
        )
        guard !sanitized.isEmpty else { return }
        let strategy = InjectionRouter.strategy(routing: settings.settings.outputRouting,
                                                isTerminal: target.isTerminal)
        let plan = InjectionPlan(target: target, strategy: strategy, stripTrailingNewlines: true)
        isReinserting = true
        defer { isReinserting = false }
        do {
            try await injector(for: strategy).inject(sanitized, plan: plan)
            lastResult = sanitized
            if soundFeedback { Feedback.inserted() }
        } catch {
            lastError = Self.injectionMessage(error)
        }
    }

    public func purgeHistory() async {
        try? await history?.purge()
    }

    public var hasCompletedOnboarding: Bool { settings.settings.hasCompletedOnboarding }

    public func completeOnboarding() {
        settings.update { $0.hasCompletedOnboarding = true }
    }

    /// Minimum permission to dictate (mic). Accessibility/Input-Monitoring are
    /// degradable: without them we still transcribe and copy to the clipboard.
    public var permissionsReady: Bool { permissions.microphone == .granted }

    public func refreshPermissions() { permissions.refresh() }

    public func requestOpenSettings() { onOpenSettings?() }

    public var soundFeedback: Bool {
        get { settings.settings.soundFeedback }
        set { settings.update { $0.soundFeedback = newValue } }
    }

    public var outputRouting: OutputRouting {
        get { settings.settings.outputRouting }
        set { settings.update { $0.outputRouting = newValue } }
    }

    public var enhancedHUD: Bool {
        get { settings.settings.enhancedHUD }
        set { settings.update { $0.enhancedHUD = newValue } }
    }

    /// Push the latest smoothed mic level to the HUD (called from the feed loops).
    func setInputLevel(_ level: Float) { inputLevel = level }

    public func requestPermission(_ kind: PermissionKind) {
        switch kind {
        case .microphone:      Task { await permissions.requestMicrophone() }
        case .accessibility:   permissions.requestAccessibility()
        case .inputMonitoring: permissions.requestInputMonitoring()
        }
    }

    /// Bind the hotkey and warm the STT model.
    public func activate() {
        permissions.refresh()
        hotkey.update(HotkeyConfig(settings.settings.hotkey))   // restore saved hotkey
        hotkey.onStart = { [weak self] in
            Task { @MainActor in self?.startDictation() }
        }
        hotkey.onStop = { [weak self] in
            Task { @MainActor in self?.stopDictation() }
        }
        hotkey.start()

        // Hands-free toggle (second hotkey): each press toggles continuous, VAD-gated dictation.
        handsFreeHotkey.update(HotkeyConfig(settings.settings.handsFreeHotkey))
        handsFreeHotkey.onStart = { [weak self] in
            Task { @MainActor in self?.toggleHandsFree() }
        }
        handsFreeHotkey.onStop = { [weak self] in
            Task { @MainActor in self?.toggleHandsFree() }
        }
        handsFreeHotkey.start()

        Task { await prepareModel() }
        // The LLM model is loaded lazily on first LLM-mode use (see produceText),
        // never at launch — so a model-load failure can't block app startup.
    }

    public func deactivate() {
        hotkey.stop()
        handsFreeHotkey.stop()
        feedTask?.cancel()
        resultTask?.cancel()
        llmTask?.cancel()
        handsFreeTask?.cancel()
        audio?.stop()
        handsFreeAudio?.stop()
        inputLevel = 0   // don't leave a frozen meter behind (ADV-001)
    }

    private func prepareModel() async {
        prepareToken += 1
        let token = prepareToken
        do {
            try await stt.prepare(locale: settings.settings.localeID)
            guard token == prepareToken else { return }  // a newer locale superseded this
            isModelReady = true
            BarkLog.pipeline.info("model ready")
        } catch {
            guard token == prepareToken else { return }
            isModelReady = false
            lastError = Self.describe(error)
            BarkLog.pipeline.error("model prepare failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Warm the STT model without binding the global hotkey (used by tests and
    /// callers that drive start/stop directly).
    public func warmModel() async { await prepareModel() }

    // MARK: - Start / stop

    public func startDictation() {
        guard !machine.isActive, !handsFreeActive else { return }   // one mic owner at a time
        // Recover from a previous .completed / .failed run so the hotkey always works.
        if machine.phase != .idle { machine.handle(.reset) }
        lastError = nil

        guard permissions.microphone == .granted else {
            fail("Microphone access is required. Grant it in System Settings.")
            permissions.openSettings(for: .microphone)
            return
        }
        guard isModelReady else {
            fail("Speech model is still preparing — try again in a moment.")
            return
        }

        capturedTarget = targetProvider()
        finalSegments = []
        volatileTail = ""
        liveText = ""
        guard machine.handle(.startPressed) else { return }   // refuse if not a legal start
        phase = machine.phase

        let engine = audioFactory()
        self.audio = engine
        Task { await beginPipeline(engine: engine) }
    }

    private func beginPipeline(engine: AudioCapturing) async {
        // The user may have released/stopped during the async setup gap.
        guard machine.phase == .listening else { engine.stop(); return }
        do {
            let sttStream = try await stt.beginStream()
            guard machine.phase == .listening else { engine.stop(); await stt.cancel(); return }
            if soundFeedback { Feedback.started() }   // pre-roll BEFORE the mic opens (no bleed)
            let audioStream = try engine.start()
            machine.handle(.audioStarted)

            feedTask = Task { [stt, weak self] in
                var meter = LevelMeter()
                for await frames in audioStream {
                    await stt.feed(frames)
                    let level = meter.update(rms: VoiceActivityDetector.rms(frames.samples))
                    self?.setInputLevel(level)
                }
                self?.setInputLevel(0)
            }
            resultTask = Task { @MainActor [weak self] in
                do {
                    for try await result in sttStream {
                        self?.apply(result)
                    }
                } catch {
                    self?.fail(Self.describe(error))
                }
            }
        } catch {
            fail(Self.describe(error))
        }
    }

    public func stopDictation() {
        guard machine.phase == .listening else { return }
        machine.handle(.stopPressed)
        phase = machine.phase
        Task { await finishPipeline() }
    }

    private func finishPipeline() async {
        audio?.stop()                 // ends audioStream → feedTask completes
        await feedTask?.value
        do {
            try await stt.finishStream()
        } catch {
            BarkLog.stt.error("finishStream: \(String(describing: error), privacy: .public)")
        }
        await resultTask?.value

        let transcript = (finalSegments.joined(separator: " ") + " " + volatileTail)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        machine.handle(.transcriptFinalized)
        phase = machine.phase

        guard !transcript.isEmpty else {
            BarkLog.pipeline.info("empty transcript — nothing to inject")
            reset()
            return
        }

        let mode = effectiveMode()
        let cleaned = await produceText(transcript, mode: mode)
        await inject(cleaned, transcript: transcript, mode: mode)
    }

    // MARK: - Cleanup

    private func produceText(_ transcript: String, mode: Mode) async -> String {
        // Always run the instant deterministic pass first.
        let basic = BasicTextCleaner.process(transcript, mode: mode)

        // Lazily load the model on first LLM-mode use (non-blocking; this
        // utterance falls back to deterministic until it's ready).
        if mode.usesLLM, settings.settings.llmEnabled, llmEnginePresent {
            switch llmStatus {
            case .notLoaded, .failed: prepareLLM()
            default: break
            }
        }

        guard mode.usesLLM, settings.settings.llmEnabled, let llm = llmCleaner, await llm.isAvailable else {
            return basic
        }

        machine.handle(.cleanupStarted)
        phase = machine.phase
        do {
            let rewritten = try await withThrowingDeadline(seconds: cleanupDeadline) {
                try await llm.clean(basic, mode: mode)
            }
            let validated = try OutputValidator.validate(rewritten, against: basic)
            machine.handle(.cleanupFinished)
            phase = machine.phase
            return validated
        } catch {
            // LLM never blocks delivery — fall back to deterministic text.
            BarkLog.cleanup.error("LLM cleanup failed, using basic: \(String(describing: error), privacy: .public)")
            machine.handle(.cleanupFinished)
            phase = machine.phase
            return basic
        }
    }

    // MARK: - Injection

    /// Push-to-talk injection: failures are fatal to the (single) session.
    private func inject(_ rawText: String, transcript: String, mode: Mode) async {
        do {
            try await performInjection(rawText, transcript: transcript, mode: mode)
        } catch {
            fail(Self.injectionMessage(error))
        }
    }

    /// Does the actual injection; throws on failure so the CALLER decides whether
    /// it's fatal. Hands-free catches locally (per-utterance) so one refusal can't
    /// kill the whole session (ADV-001).
    private func performInjection(_ rawText: String, transcript: String, mode: Mode) async throws {
        guard let target = capturedTarget ?? targetProvider() else {
            throw InjectionError.focusChanged
        }

        // Terminal sinks: keep text only, never anything that could submit.
        let sanitized = TextSanitizer.sanitize(
            rawText,
            options: .init(allowNewlines: !target.isTerminal, stripTrailingNewlines: true)
        )
        guard !sanitized.isEmpty else { reset(); return }

        phase = machine.phase  // produceText already left the machine in .injecting
        let strategy = InjectionRouter.strategy(routing: settings.settings.outputRouting,
                                                isTerminal: target.isTerminal)
        let plan = InjectionPlan(target: target, strategy: strategy, stripTrailingNewlines: true)
        try await injector(for: strategy).inject(sanitized, plan: plan)

        machine.handle(.injected)
        phase = machine.phase
        lastResult = sanitized
        if soundFeedback { Feedback.inserted() }
        recordHistory(transcript: transcript, output: sanitized, mode: mode, target: target)
        reset()
    }

    private func injector(for strategy: InjectionStrategy) -> TextInjector {
        switch strategy {
        case .copyOnly:  return clipboardInjector
        case .keystroke: return keystrokeInjector
        case .paste:     return pasteInjector
        }
    }

    static func injectionMessage(_ error: Error) -> String {
        switch error {
        case InjectionError.secureFieldBlocked: return "Refused: a password/secure field is focused."
        case InjectionError.focusChanged: return "Window focus changed — text not inserted."
        default: return "Couldn't insert text: \(describe(error))"
        }
    }

    // MARK: - Helpers

    private func recordHistory(transcript: String, output: String, mode: Mode, target: InjectionTarget) {
        guard settings.settings.historyEnabled, let history else { return }
        let record = HistoryRecord(transcript: transcript, output: output,
                                   modeID: mode.id, appBundleID: target.bundleID)
        Task.detached {
            do { try await history.append(record) }
            catch { BarkLog.pipeline.error("history append failed") }
        }
    }

    private func apply(_ result: STTResult) {
        if result.isFinal {
            if !result.text.isEmpty { finalSegments.append(result.text) }
            volatileTail = ""
        } else {
            volatileTail = result.text
        }
        liveText = (finalSegments.joined(separator: " ") + " " + volatileTail)
            .trimmingCharacters(in: .whitespaces)
    }

    private func fail(_ message: String) {
        lastError = message
        machine.handle(.errored(message))
        phase = machine.phase
        feedTask?.cancel(); resultTask?.cancel()
        audio?.stop(); audio = nil
        capturedTarget = nil   // don't let a dead session's target bleed into per-app mode (ADV-003)
        inputLevel = 0
        Task { await stt.cancel() }
    }

    private func reset() {
        feedTask = nil; resultTask = nil
        audio = nil
        capturedTarget = nil   // effectiveMode falls back to the manual selection until the next start (ADV-003)
        machine.handle(.reset)
        phase = machine.phase
        liveText = ""
        inputLevel = 0
    }

    /// Stop a live session immediately (e.g. user rebinds the hotkey mid-dictation).
    public func cancelDictation() {
        guard machine.isActive else { return }
        feedTask?.cancel(); resultTask?.cancel()
        feedTask = nil; resultTask = nil
        audio?.stop(); audio = nil
        capturedTarget = nil   // (ADV-003)
        inputLevel = 0
        Task { await stt.cancel() }
        machine.handle(.reset)
        phase = machine.phase
        liveText = ""
    }

    // MARK: - Hands-free (voice-activated) dictation

    public var handsFreeHotkeySetting: HotkeySetting {
        get { settings.settings.handsFreeHotkey }
        set {
            guard newValue != settings.settings.hotkey else {   // no shared binding (ADV-002)
                lastError = "That key is already the push-to-talk hotkey."
                return
            }
            settings.update { $0.handsFreeHotkey = newValue }
            handsFreeHotkey.update(HotkeyConfig(newValue))
        }
    }

    public var vadSensitivity: VADSensitivity {
        get { settings.settings.vadSensitivity }
        set { settings.update { $0.vadSensitivity = newValue } }
    }

    public func toggleHandsFree() {
        handsFreeActive ? stopHandsFree() : startHandsFree()
    }

    public func startHandsFree() {
        guard !handsFreeActive, !machine.isActive else { return }  // one mic owner
        lastError = nil
        guard permissions.microphone == .granted else {
            fail("Microphone access is required. Grant it in System Settings.")
            permissions.openSettings(for: .microphone)
            return
        }
        guard isModelReady else {
            fail("Speech model is still preparing — try again in a moment.")
            return
        }
        handsFreeActive = true
        onHandsFreeChange?(true)
        let engine = audioFactory()
        handsFreeAudio = engine
        handsFreeTask = Task { [weak self] in await self?.runHandsFree(engine) }
    }

    public func stopHandsFree() {
        guard handsFreeActive else { return }
        handsFreeActive = false
        handsFreeTask?.cancel(); handsFreeTask = nil
        handsFreeAudio?.stop(); handsFreeAudio = nil
        Task { await stt.cancel() }
        machine.handle(.reset); phase = machine.phase
        liveText = ""
        inputLevel = 0
        onHandsFreeChange?(false)
    }

    /// Continuous, VAD-gated loop: detect speech onset → capture the utterance →
    /// on silence, finalize → clean → inject → keep listening. Until toggled off.
    private func runHandsFree(_ engine: AudioCapturing) async {
        let stream: AsyncStream<AudioFrames>
        do { stream = try engine.start() }
        catch { fail(Self.describe(error)); stopHandsFree(); return }

        var vad = VoiceActivityDetector(config: VADConfig(sensitivity: settings.settings.vadSensitivity))
        var capturing = false
        var preroll: [AudioFrames] = []
        let prerollMax = 3   // ~300 ms, so we don't clip speech onset
        var resultConsumer: Task<Void, Never>?
        var capturedFrames = 0
        let maxUtteranceFrames = 300   // ~30 s safety cap (never-ending speech/noise)
        var meter = LevelMeter()

        for await frames in stream {
            guard handsFreeActive, !Task.isCancelled else { break }
            let event = vad.process(frames)
            inputLevel = meter.update(rms: VoiceActivityDetector.rms(frames.samples))

            if !capturing {
                preroll.append(frames)
                if preroll.count > prerollMax { preroll.removeFirst() }
                guard event == .speechStarted else { continue }

                capturedTarget = targetProvider()
                finalSegments = []; volatileTail = ""; liveText = ""
                machine.handle(.reset); machine.handle(.startPressed); machine.handle(.audioStarted)
                phase = machine.phase
                if soundFeedback { Feedback.started() }
                do {
                    let results = try await stt.beginStream()
                    resultConsumer = Task { @MainActor [weak self] in
                        do { for try await r in results { self?.apply(r) } } catch {}
                    }
                    for f in preroll { await stt.feed(f) }
                    preroll.removeAll()
                    capturing = true
                    capturedFrames = 0
                } catch {
                    // STT failed to start: don't keep the mic open silently (Codex).
                    lastError = "Couldn't start the speech engine — hands-free turned off."
                    stopHandsFree()
                    return
                }
            } else {
                await stt.feed(frames)
                capturedFrames += 1
                // Finalize on silence, or force-finalize at the safety cap.
                guard event == .speechEnded || capturedFrames >= maxUtteranceFrames else { continue }

                machine.handle(.stopPressed); phase = machine.phase
                try? await stt.finishStream()
                await resultConsumer?.value
                resultConsumer = nil
                capturing = false

                let transcript = (finalSegments.joined(separator: " ") + " " + volatileTail)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if transcript.isEmpty {
                    machine.handle(.reset); phase = machine.phase
                } else {
                    let mode = effectiveMode()
                    machine.handle(.transcriptFinalized); phase = machine.phase
                    let cleaned = await produceText(transcript, mode: mode)
                    // Toggled off (or cancelled) during cleanup → do NOT inject (Codex).
                    guard handsFreeActive, !Task.isCancelled else { break }
                    // Per-utterance: an injection refusal must NOT kill the session (ADV-001).
                    do {
                        try await performInjection(cleaned, transcript: transcript, mode: mode)
                    } catch {
                        lastError = Self.injectionMessage(error)
                        machine.handle(.reset); phase = machine.phase
                    }
                }
                vad.reset()
                finalSegments = []; volatileTail = ""; liveText = ""
            }
        }
        // Stream ended (device loss / abnormal finish). Clear the meter and, if we
        // still believe we're live, tear the session down so the HUD doesn't freeze
        // and the next hotkey isn't silently swallowed (ADV-001). If stopHandsFree
        // drove us here it already flipped handsFreeActive off, so this is a no-op.
        inputLevel = 0
        if handsFreeActive {
            handsFreeActive = false
            handsFreeAudio?.stop(); handsFreeAudio = nil
            machine.handle(.reset); phase = machine.phase
            liveText = ""
            onHandsFreeChange?(false)
        }
    }

    static func describe(_ error: Error) -> String {
        if let stt = error as? STTError {
            switch stt {
            case .modelNotInstalled(let l): return "Speech model for \(l) is not installed."
            case .localeUnsupported(let l): return "Language \(l) isn't supported on-device."
            case .notPrepared: return "Speech engine not ready."
            case .engineFailure(let m): return m
            }
        }
        return (error as NSError).localizedDescription
    }
}

/// Runs `body` but guarantees a return by `seconds` even if `body` ignores
/// cancellation: on timeout the work task is cancelled and its (late) result is
/// dropped, and we resume with `CleanupError.timedOut`. A one-shot gate ensures
/// the continuation resumes exactly once.
private final class DeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}

func withThrowingDeadline<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = DeadlineGate()
    let work = Task { try await body() }
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        Task {
            do {
                let value = try await work.value
                if gate.claim() { cont.resume(returning: value) }
            } catch {
                if gate.claim() { cont.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if gate.claim() { work.cancel(); cont.resume(throwing: CleanupError.timedOut) }
        }
    }
}
