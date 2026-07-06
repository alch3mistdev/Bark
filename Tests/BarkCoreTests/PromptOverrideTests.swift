import XCTest
@testable import BarkCore

final class PromptOverrideTests: XCTestCase {
    // MARK: - Override application

    func testApplyingOverrideReplacesOnlyDefinedFields() {
        let edited = Mode.email.applyingOverride(PromptOverride(systemPrompt: "Casual email."))
        XCTAssertEqual(edited.systemPrompt, "Casual email.")
        XCTAssertEqual(edited.revisionPrompt, Mode.email.revisionPrompt)   // untouched
        // Identity and non-prompt fields never overridden.
        XCTAssertEqual(edited.id, Mode.email.id)
        XCTAssertEqual(edited.name, Mode.email.name)
        XCTAssertEqual(edited.usesLLM, Mode.email.usesLLM)
        XCTAssertEqual(edited.stripFillers, Mode.email.stripFillers)
    }

    func testApplyingNilOverrideIsIdentity() {
        XCTAssertEqual(Mode.email.applyingOverride(nil), Mode.email)
    }

    func testEmptyStringOverrideIsMeaningful() {
        // nil = untouched; "" = cleared (engine fallback applies).
        let cleared = Mode.email.applyingOverride(PromptOverride(systemPrompt: ""))
        XCTAssertEqual(cleared.systemPrompt, "")
        XCTAssertEqual(PromptTemplate.system(for: cleared),
                       PromptTemplate.guardrail + "\n\nTask: Fix grammar, punctuation, and capitalization.")
    }

    // MARK: - Pruning predicates

    func testIsEmptyAndIsNoOp() {
        XCTAssertTrue(PromptOverride().isEmpty)
        XCTAssertFalse(PromptOverride(systemPrompt: "").isEmpty)
        // Equal to the shipped default → no-op → must be pruned.
        XCTAssertTrue(PromptOverride(systemPrompt: Mode.email.systemPrompt).isNoOp(for: .email))
        XCTAssertTrue(PromptOverride(revisionPrompt: Mode.email.revisionPrompt).isNoOp(for: .email))
        XCTAssertFalse(PromptOverride(systemPrompt: "different").isNoOp(for: .email))
        // "" revision on a mode that ships none: both resolve to the generic
        // refine instruction, so it's a no-op — but a real clear when the mode
        // ships a revision prompt.
        XCTAssertNil(Mode.message.revisionPrompt)
        XCTAssertTrue(PromptOverride(revisionPrompt: "").isNoOp(for: .message))
        XCTAssertFalse(PromptOverride(revisionPrompt: "").isNoOp(for: .email))
    }

    // MARK: - Length bound (FR-009)

    func testFieldLengthValidation() {
        let atLimit = String(repeating: "a", count: PromptOverride.maxFieldLength)
        XCTAssertTrue(PromptOverride(systemPrompt: atLimit).isValid)
        XCTAssertFalse(PromptOverride(systemPrompt: atLimit + "a").isValid)
        XCTAssertFalse(PromptOverride(revisionPrompt: atLimit + "a").isValid)
        XCTAssertTrue(PromptOverride().isValid)
    }

    // MARK: - Settings.effectiveModes

    func testEffectiveModesAppliesOverridesAndKeepsCustoms() {
        var s = Settings.default
        s.builtInPromptOverrides["email"] = PromptOverride(systemPrompt: "Casual email.")
        s.customModes = [Mode(id: "legal", name: "Legal", usesLLM: true, systemPrompt: "Formal.")]

        let modes = s.effectiveModes()
        XCTAssertEqual(modes.first { $0.id == "email" }?.systemPrompt, "Casual email.")
        XCTAssertEqual(modes.first { $0.id == "message" }?.systemPrompt, Mode.message.systemPrompt) // others untouched
        XCTAssertEqual(modes.first { $0.id == "legal" }?.systemPrompt, "Formal.")
        XCTAssertEqual(modes.count, Mode.builtInModes.count + 1)
    }

    func testInvalidPersistedOverrideIsIgnored() {
        // A hand-edited defaults payload over the field bound must not reach
        // the LLM prompt (FR-009 defense in depth, ADV-004).
        var s = Settings.default
        s.builtInPromptOverrides["email"] = PromptOverride(
            systemPrompt: String(repeating: "a", count: PromptOverride.maxFieldLength + 1))
        XCTAssertEqual(s.effectiveModes().first { $0.id == "email" }?.systemPrompt,
                       Mode.email.systemPrompt)
    }

    func testUnknownOverrideKeyIsInert() {
        var s = Settings.default
        s.builtInPromptOverrides["no-such-mode"] = PromptOverride(systemPrompt: "x")
        XCTAssertEqual(s.effectiveModes(), Settings.default.effectiveModes())
    }

    func testResetSemantics() {
        var s = Settings.default
        s.builtInPromptOverrides["email"] = PromptOverride(systemPrompt: "Casual email.")
        s.builtInPromptOverrides["email"] = nil   // reset = remove override
        XCTAssertEqual(s.effectiveModes().first { $0.id == "email" }?.systemPrompt,
                       Mode.email.systemPrompt)   // current shipped default back in effect
    }

    // MARK: - Byte-identity: displayed constants == sent prompt (SC-001, SC-006)

    func testAssembledPromptStartsWithGuardrailAndContainsOverrideText() {
        for shipped in Mode.builtInModes {
            let override = PromptOverride(systemPrompt: "EDITED-TASK-\(shipped.id)",
                                          revisionPrompt: "EDITED-REVISION-\(shipped.id)")
            let mode = shipped.applyingOverride(override)

            let system = PromptTemplate.system(for: mode)
            XCTAssertTrue(system.hasPrefix(PromptTemplate.guardrail + "\n\nTask: "))
            XCTAssertEqual(system, PromptTemplate.guardrail + "\n\nTask: EDITED-TASK-\(shipped.id)")

            let refine = PromptTemplate.refineSystem(for: mode)
            XCTAssertTrue(refine.hasPrefix(PromptTemplate.refineGuardrail + "\n\nInstruction style: "))
            XCTAssertEqual(refine, PromptTemplate.refineGuardrail + "\n\nInstruction style: EDITED-REVISION-\(shipped.id)")
        }
    }

    // MARK: - Custom modes (US3)

    func testCustomModeRevisionPromptRoundTripsAndDrivesRefine() throws {
        let custom = Mode(id: "custom-legal", name: "Legal", usesLLM: true,
                          systemPrompt: "Formal legal register.",
                          revisionPrompt: "Keep citations verbatim.")
        var s = Settings.default
        s.customModes = [custom]

        let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        let loaded = try XCTUnwrap(round.effectiveModes().first { $0.id == "custom-legal" })
        XCTAssertEqual(loaded.revisionPrompt, "Keep citations verbatim.")
        XCTAssertEqual(PromptTemplate.refineSystem(for: loaded),
                       PromptTemplate.refineGuardrail + "\n\nInstruction style: Keep citations verbatim.")
    }

    func testLegacyCustomModeWithoutRevisionPromptFallsBackToGeneric() throws {
        // Pre-013 persisted custom mode: no revisionPrompt key at all.
        let json = #"{"customModes":[{"id":"custom-old","name":"Old","symbol":"star","usesLLM":true,"systemPrompt":"Rewrite.","stripFillers":true,"smartCapitalize":true,"applySpokenPunctuation":true,"fixSpacing":true}]}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let old = try XCTUnwrap(s.effectiveModes().first { $0.id == "custom-old" })
        XCTAssertNil(old.revisionPrompt)
        XCTAssertEqual(PromptTemplate.refineSystem(for: old),
                       PromptTemplate.refineGuardrail + "\n\nInstruction style: " + PromptTemplate.genericRefineInstruction)
    }

    func testAssembledPromptWithoutOverrideMatchesShippedDefaults() {
        for shipped in Mode.builtInModes where shipped.usesLLM {
            XCTAssertEqual(PromptTemplate.system(for: shipped),
                           PromptTemplate.guardrail + "\n\nTask: " + shipped.systemPrompt)
        }
        // No revision prompt → generic refine instruction.
        XCTAssertEqual(PromptTemplate.refineSystem(for: .message),
                       PromptTemplate.refineGuardrail + "\n\nInstruction style: " + PromptTemplate.genericRefineInstruction)
    }
}
