import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

@MainActor
final class SmartRepliesTests: XCTestCase {
    private func makeController(
        context: ConversationContext?,
        suggester: BranchSuggester? = nil,
        injector: FakeInjector = FakeInjector()
    ) -> (DictationController, FakeContextProvider, FakeInjector) {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "bark-sr-\(UUID().uuidString)")!, key: "k")
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        let provider = FakeContextProvider(context)
        let c = DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(), llmCleaner: nil, history: nil,
            branchSuggester: suggester, contextProvider: provider,
            audioFactory: { FakeAudioCapture() },
            pasteInjector: injector, keystrokeInjector: FakeInjector(),
            targetProvider: { InjectionTarget(pid: 1, bundleID: "com.example.chat") }
        )
        return (c, provider, injector)
    }

    func testDisabledReadsNothing() async {
        let (c, provider, _) = makeController(context: ConversationContext(lastMessage: "Should I go?"))
        XCTAssertFalse(c.smartRepliesEnabled)
        await c.prepareBranchContext()
        XCTAssertEqual(provider.reads, 0)
        XCTAssertTrue(c.branchOptions.isEmpty)
        XCTAssertFalse(c.hasBranchContext)
    }

    func testYesNoQuickReplies() async {
        let (c, _, _) = makeController(context: ConversationContext(lastMessage: "Should I merge the PR?"))
        c.smartRepliesEnabled = true
        await c.prepareBranchContext()
        XCTAssertEqual(c.branchOptions.map(\.payload), ["Yes", "No"])
        XCTAssertFalse(c.branchUsedLLM)
        XCTAssertTrue(c.hasBranchContext)
    }

    func testGenericQuickReplies() async {
        let (c, _, _) = makeController(context: ConversationContext(lastMessage: "Here are some options."))
        c.smartRepliesEnabled = true
        await c.prepareBranchContext()
        XCTAssertEqual(c.branchOptions, BasicBranchSuggester.genericReplies)
    }

    func testNoContextShowsNotice() async {
        let (c, provider, _) = makeController(context: nil)
        c.smartRepliesEnabled = true
        await c.prepareBranchContext()
        XCTAssertEqual(provider.reads, 1)
        XCTAssertTrue(c.branchOptions.isEmpty)
        XCTAssertNotNil(c.branchNotice)
        XCTAssertFalse(c.hasBranchContext)
    }

    func testLLMReplacesQuickReplies() async {
        let llmOptions = [BranchOption("Ship it now"), BranchOption("Hold for review")]
        let (c, _, _) = makeController(
            context: ConversationContext(lastMessage: "What should we do next?"),
            suggester: FakeBranchSuggester(.ok(llmOptions))
        )
        c.smartRepliesEnabled = true
        c.llmEnabled = true
        await c.prepareBranchContext()
        await c.requestLLMSuggestions()
        XCTAssertEqual(c.branchOptions, llmOptions)
        XCTAssertTrue(c.branchUsedLLM)
    }

    func testLLMFailureFallsBackToQuickReplies() async {
        let (c, _, _) = makeController(
            context: ConversationContext(lastMessage: "Pick an approach."),
            suggester: FakeBranchSuggester(.fail)
        )
        c.smartRepliesEnabled = true
        c.llmEnabled = true
        await c.prepareBranchContext()
        let quick = c.branchOptions
        await c.requestLLMSuggestions()
        XCTAssertEqual(c.branchOptions, quick)        // unchanged
        XCTAssertFalse(c.branchUsedLLM)
        XCTAssertNotNil(c.branchNotice)
    }

    func testLLMEmptyFallsBack() async {
        let (c, _, _) = makeController(
            context: ConversationContext(lastMessage: "Pick an approach."),
            suggester: FakeBranchSuggester(.empty)
        )
        c.smartRepliesEnabled = true
        c.llmEnabled = true
        await c.prepareBranchContext()
        let quick = c.branchOptions
        await c.requestLLMSuggestions()
        XCTAssertEqual(c.branchOptions, quick)
        XCTAssertFalse(c.branchUsedLLM)
    }

    func testLLMSkippedWhenSuggesterUnavailable() async {
        let (c, _, _) = makeController(
            context: ConversationContext(lastMessage: "Pick an approach."),
            suggester: FakeBranchSuggester(.ok([BranchOption("x")]), available: false)
        )
        c.smartRepliesEnabled = true
        c.llmEnabled = true
        await c.prepareBranchContext()
        await c.requestLLMSuggestions()
        XCTAssertFalse(c.branchUsedLLM)
        XCTAssertNotNil(c.branchNotice)
    }

    func testChooseBranchInjectsPayloadAndClears() async {
        let injector = FakeInjector()
        let (c, _, _) = makeController(
            context: ConversationContext(lastMessage: "Should I deploy?"),
            injector: injector
        )
        c.smartRepliesEnabled = true
        await c.prepareBranchContext()
        guard let yes = c.branchOptions.first else { return XCTFail("no options") }
        await c.chooseBranch(yes)
        XCTAssertEqual(injector.last, "Yes")
        XCTAssertEqual(injector.count, 1)
        XCTAssertTrue(c.branchOptions.isEmpty)   // cleared after pick
        XCTAssertFalse(c.hasBranchContext)
        XCTAssertEqual(c.lastResult, "Yes")
    }

    func testDisablingClearsSuggestions() async {
        let (c, _, _) = makeController(context: ConversationContext(lastMessage: "Should I go?"))
        c.smartRepliesEnabled = true
        await c.prepareBranchContext()
        XCTAssertFalse(c.branchOptions.isEmpty)
        c.smartRepliesEnabled = false
        XCTAssertTrue(c.branchOptions.isEmpty)
        XCTAssertFalse(c.hasBranchContext)
    }
}
