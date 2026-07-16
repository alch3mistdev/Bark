import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// US3 flow tests (015 T039/T040): backend selection with fail-toward-local
/// (never the reverse — R8), and history-informed suggestions from the
/// existing opt-in store (FR-015).
@MainActor
final class SuggestionBackendAndHistoryTests: XCTestCase {
    private let editorTarget = InjectionTarget(pid: 4343, bundleID: "com.example.Safari")

    private func makeContext(fieldLabel: String? = nil, windowText: String = "Please enter your details") -> CapturedContext {
        CapturedContext(source: .accessibility, appBundleID: "com.example.Safari", windowTitle: "Checkout",
                        fieldLabel: fieldLabel, fieldValue: nil, fieldPlaceholder: nil, fieldRole: "AXTextField",
                        windowText: windowText)
    }

    private struct Harness {
        let suggestions: SuggestionController
        let local: FakeSuggestionEngine
        let external: FakeSuggestionEngine?
        let paste: FakeInjector
    }

    private func make(
        backend: SuggestionBackendID,
        local: FakeSuggestionEngine = FakeSuggestionEngine(.ok(#"["from local"]"#)),
        external: FakeSuggestionEngine? = nil,
        endpoint: String = "http://localhost:11434/v1",
        model: String = "qwen3:8b",
        llmEnabled: Bool = true,
        history: HistoryStore? = nil,
        historyEnabled: Bool = false,
        context: CapturedContext? = nil
    ) -> Harness {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "sug-us3-\(UUID().uuidString)")!, key: "k")
        settings.update {
            $0.suggestionsEnabled = true
            $0.llmEnabled = llmEnabled
            $0.suggestionBackend = backend
            $0.externalLLMEndpoint = endpoint
            $0.externalLLMModel = model
            $0.historyEnabled = historyEnabled
        }
        let perms = PermissionsCoordinator()
        let dictation = DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(), llmCleaner: FakeCleaner(.ok("x")), history: history,
            targetProvider: { [target = editorTarget] in target }
        )
        let paste = FakeInjector()
        let provider: (@MainActor (String, String, String?) -> SuggestionEngine)?
        if let external {
            provider = { _, _, _ in external }
        } else {
            provider = nil
        }
        let suggestions = SuggestionController(
            settings: settings, dictation: dictation, hotkey: HotkeyManager(),
            capture: FakeContextCapture(.ok(context ?? makeContext())),
            localEngine: local,
            externalEngineProvider: provider,
            secretStore: InMemorySecretStore(),
            history: history,
            pasteInjector: paste, keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector(), returnSynthesizer: FakeReturnSynthesizer(),
            targetProvider: { [target = editorTarget] in target },
            secureInputCheck: { false },
            generationDeadline: 5, settleDelay: .zero
        )
        return Harness(suggestions: suggestions, local: local, external: external, paste: paste)
    }

    private func waitFor(_ condition: @autoclosure @MainActor () -> Bool, timeout: Double = 4) async {
        for _ in 0..<Int(timeout * 50) {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Backend selection + fallback (T039)

    func testExternalBackendUsedWhenConfigured() async {
        let external = FakeSuggestionEngine(.ok(#"["from external"]"#))
        let h = make(backend: .external, external: external)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        XCTAssertEqual(h.suggestions.session.candidates, ["from external"])
        XCTAssertTrue(h.local.requests.isEmpty)
    }

    func testExternalFailureFallsBackToLocal() async {
        let external = FakeSuggestionEngine(.fail(.http(401)))
        let h = make(backend: .external, external: external)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        XCTAssertEqual(h.suggestions.session.candidates, ["from local"])   // R8: failed toward privacy
        XCTAssertEqual(external.requests.count, 1)
        XCTAssertEqual(h.local.requests.count, 1)
    }

    func testExternalFailureWithNoLocalShowsEndpointError() async {
        let external = FakeSuggestionEngine(.fail(.http(401)))
        let h = make(backend: .external, external: external, llmEnabled: false)   // local not usable
        h.suggestions.handleHotkey()
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())
        XCTAssertEqual(h.suggestions.session.phase,
                       .failed("The endpoint returned HTTP 401 — check Settings → Suggest."))
        XCTAssertTrue(h.local.requests.isEmpty)
    }

    func testLocalFailureNeverEscalatesToExternal() async {
        let external = FakeSuggestionEngine(.ok(#"["should never be used"]"#))
        let h = make(backend: .local,
                     local: FakeSuggestionEngine(.fail(.engineUnavailable)),
                     external: external)
        h.suggestions.handleHotkey()
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())
        XCTAssertTrue(external.requests.isEmpty)   // R8: the reverse direction is forbidden
    }

    func testUnconfiguredEndpointFailsHonestly() async {
        let h = make(backend: .external, external: FakeSuggestionEngine(.ok("[]")), endpoint: "")
        h.suggestions.handleHotkey()
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())
        XCTAssertEqual(h.suggestions.session.phase,
                       .failed("Configure the custom endpoint in Settings → Suggest."))
    }

    // MARK: - History-informed suggestions (T040)

    func testFieldLabelPullsMatchingHistoryIntoThePrompt() async {
        let store = InMemoryHistoryStore([
            HistoryRecord(transcript: "", output: "My address is 42 Foo Street, Nairobi", modeID: "clean", appBundleID: nil),
            HistoryRecord(transcript: "", output: "Unrelated meeting notes", modeID: "clean", appBundleID: nil),
        ])
        let h = make(backend: .local, history: store, historyEnabled: true,
                     context: makeContext(fieldLabel: "Address", windowText: "Shipping address for your order"))
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)

        let request = h.local.requests.first
        XCTAssertNotNil(request)
        XCTAssertTrue(request!.user.contains(SuggestionPrompt.historyOpenTag))
        XCTAssertTrue(request!.user.contains("42 Foo Street, Nairobi"))       // overlaps the "address" keyword
        XCTAssertFalse(request!.user.contains("Unrelated meeting notes"))
    }

    func testHistoryDisabledSendsNoSnippets() async {
        let store = InMemoryHistoryStore([
            HistoryRecord(transcript: "", output: "42 Foo Street address", modeID: "clean", appBundleID: nil),
        ])
        let h = make(backend: .local, history: store, historyEnabled: false,
                     context: makeContext(fieldLabel: "Address"))
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        XCTAssertFalse(h.local.requests.first!.user.contains(SuggestionPrompt.historyOpenTag))
    }

    func testAcceptedSuggestionRecordedWithoutContext() async {
        let store = InMemoryHistoryStore()
        let h = make(backend: .local, history: store, historyEnabled: true)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.choose(0)
        await waitFor(h.suggestions.session.phase == .idle)

        var records: [HistoryRecord] = []
        for _ in 0..<100 {
            records = await store.all()
            if records.count == 1 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].output, "from local")
        XCTAssertEqual(records[0].transcript, "")               // R7: no screen content in history
        XCTAssertEqual(records[0].modeID, "suggestion")
    }
}
