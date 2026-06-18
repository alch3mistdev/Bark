import Foundation
import Observation
import BarkCore
import BarkEngines

/// The conductor. Wires hotkey → audio capture → STT → cleanup → injection,
/// driving the pure `DictationStateMachine`. Lives on the main actor; the heavy
/// work (capture, STT, LLM) runs in engines off the main thread.
@MainActor
@Observable
public final class DictationController {
    // Observable UI state
    public private(set) var phase: DictationPhase = .idle
    public private(set) var liveText: String = ""
    public private(set) var lastError: String?
    public private(set) var isModelReady = false

    // Collaborators
    public let settings: SettingsStore
    public let permissions: PermissionsCoordinator
    private let hotkey: HotkeyManager
    private let audioFactory: @Sendable () -> AudioCapturing
    private let stt: STTEngine
    private let basicCleaner = BasicTextCleaner()
    private let llmCleaner: TextCleaner?
    private let pasteInjector: TextInjector
    private let keystrokeInjector: TextInjector
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
    private var prepareToken = 0

    public init(
        settings: SettingsStore,
        permissions: PermissionsCoordinator,
        hotkey: HotkeyManager,
        stt: STTEngine,
        llmCleaner: TextCleaner?,
        history: HistoryStore? = nil,
        audioFactory: @escaping @Sendable () -> AudioCapturing = { AudioCaptureEngine() },
        pasteInjector: TextInjector = PasteboardInjector(),
        keystrokeInjector: TextInjector = KeystrokeInjector(),
        cleanupDeadline: Double = 8,
        targetProvider: @escaping @MainActor () -> InjectionTarget? = { FocusProbe.currentTarget() }
    ) {
        self.settings = settings
        self.permissions = permissions
        self.hotkey = hotkey
        self.stt = stt
        self.llmCleaner = llmCleaner
        self.history = history
        self.audioFactory = audioFactory
        self.pasteInjector = pasteInjector
        self.keystrokeInjector = keystrokeInjector
        self.cleanupDeadline = cleanupDeadline
        self.targetProvider = targetProvider
    }

    public var llmAvailable: Bool { llmCleaner != nil }

    // MARK: - Settings-derived state (UI binds here; writes persist)

    public var modes: [Mode] { Mode.builtInModes + settings.settings.customModes }

    public var selectedModeID: String {
        get { settings.settings.selectedModeID }
        set { settings.update { $0.selectedModeID = newValue } }
    }

    public var currentMode: Mode { modes.first { $0.id == selectedModeID } ?? .clean }

    public var hotkeySetting: HotkeySetting {
        get { settings.settings.hotkey }
        set {
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
        set { settings.update { $0.llmEnabled = newValue } }
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

    public func historyRecords() async -> [HistoryRecord] {
        await history?.all() ?? []
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
        Task { await prepareModel() }
    }

    public func deactivate() {
        hotkey.stop()
        feedTask?.cancel()
        resultTask?.cancel()
        audio?.stop()
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
        guard !machine.isActive else { return }
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
            let audioStream = try engine.start()
            machine.handle(.audioStarted)

            feedTask = Task { [stt] in
                for await frames in audioStream {
                    await stt.feed(frames)
                }
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

        let mode = currentMode
        let cleaned = await produceText(transcript, mode: mode)
        await inject(cleaned, transcript: transcript, mode: mode)
    }

    // MARK: - Cleanup

    private func produceText(_ transcript: String, mode: Mode) async -> String {
        // Always run the instant deterministic pass first.
        let basic = BasicTextCleaner.process(transcript, mode: mode)

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

    private func inject(_ rawText: String, transcript: String, mode: Mode) async {
        let target = capturedTarget ?? targetProvider()
        guard let target else { fail("Lost the target window."); return }

        // Terminal sinks: keep text only, never anything that could submit.
        let sanitized = TextSanitizer.sanitize(
            rawText,
            options: .init(allowNewlines: !target.isTerminal, stripTrailingNewlines: true)
        )
        guard !sanitized.isEmpty else { reset(); return }

        // produceText already left the machine in .injecting (directly, or via
        // .cleaning → .cleanupFinished). Reflect it; don't bypass the machine.
        phase = machine.phase

        let plan = InjectionPlan(target: target,
                                 strategy: target.isTerminal ? .keystroke : .paste,
                                 stripTrailingNewlines: true)
        do {
            let injector = plan.strategy == .keystroke ? keystrokeInjector : pasteInjector
            try await injector.inject(sanitized, plan: plan)
            machine.handle(.injected)
            phase = machine.phase
            recordHistory(transcript: transcript, output: sanitized, mode: mode, target: target)
            reset()
        } catch InjectionError.secureFieldBlocked {
            fail("Refused: a password/secure field is focused.")
        } catch InjectionError.focusChanged {
            fail("Window focus changed — text not inserted.")
        } catch {
            fail("Couldn't insert text: \(Self.describe(error))")
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
        Task { await stt.cancel() }
    }

    private func reset() {
        feedTask = nil; resultTask = nil
        audio = nil
        machine.handle(.reset)
        phase = machine.phase
        liveText = ""
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
