import SwiftUI
import BarkCore

// MARK: - Prompt editor building blocks (013)

/// The fixed safety preamble, shown verbatim so the settings view displays
/// exactly what the engine sends — but never editable (Constitution IV).
struct GuardrailSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("Fixed safety preamble — always sent first, not editable.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// One editable instruction field with live character count against the hard
/// bound (FR-009) and an explicit empty-field fallback note (FR-010).
struct InstructionField: View {
    let title: String
    let scaffold: String            // literal joining text, e.g. "Task: "
    let emptyFallback: String       // exact text the engine substitutes when empty
    @Binding var text: String

    var overLimit: Bool { text.count > PromptOverride.maxFieldLength }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(text.count)/\(PromptOverride.maxFieldLength)")
                    .font(.caption2)
                    .foregroundStyle(overLimit ? Color.red : Color.secondary)
            }
            HStack(alignment: .top, spacing: 4) {
                Text(scaffold).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                TextEditor(text: $text).frame(minHeight: 70, maxHeight: 140).font(.callout)
            }
            if overLimit {
                Label("Over the \(PromptOverride.maxFieldLength)-character limit — shorten to save.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.red)
            } else if text.isEmpty {
                Text("Empty — the generic default is used instead: “\(emptyFallback)”")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Shared prompt sections: the exact rewrite and refine prompts (guardrail +
/// editable instruction), rendered from the same `PromptTemplate` constants
/// the engine uses so display ≡ sent (SC-001). The refine section is ALWAYS
/// shown: hold-to-refine sends the refine prompt even for deterministic
/// (non-LLM) modes (ADV-001).
struct PromptSections: View {
    let usesLLM: Bool
    @Binding var task: String
    @Binding var revision: String

    var body: some View {
        if usesLLM {
            GuardrailSection(title: "Rewrite prompt", text: PromptTemplate.guardrail)
            InstructionField(title: "Task instruction (sent after the preamble)",
                             scaffold: PromptTemplate.taskScaffold,
                             emptyFallback: PromptTemplate.defaultTaskInstruction,
                             text: $task)
        } else {
            Label("No rewrite prompt is sent for this mode — dictation uses instant deterministic cleanup only.",
                  systemImage: "bolt.fill")
                .font(.callout).foregroundStyle(.secondary)
        }
        Divider()
        GuardrailSection(title: "Refine prompt (sent only when you hold-to-refine)",
                         text: PromptTemplate.refineGuardrail)
        InstructionField(title: "Refinement instruction (sent after the preamble)",
                         scaffold: PromptTemplate.instructionStyleScaffold,
                         emptyFallback: PromptTemplate.genericRefineInstruction,
                         text: $revision)
    }

    /// Bounds every field, including ones a toggle currently hides, so Save
    /// can never silently drop an over-limit edit (ADV-002).
    var overLimit: Bool {
        task.count > PromptOverride.maxFieldLength || revision.count > PromptOverride.maxFieldLength
    }
}

/// View/edit a built-in mode's prompts. Edits are stored as an override on
/// top of the shipped default; Reset removes the override (013).
struct BuiltInPromptEditor: View {
    @Bindable var controller: DictationController
    let shipped: Mode
    var dismiss: () -> Void

    @State private var task: String
    @State private var revision: String

    init(controller: DictationController, shipped: Mode, dismiss: @escaping () -> Void) {
        self.controller = controller
        self.shipped = shipped
        self.dismiss = dismiss
        let effective = shipped.applyingOverride(controller.builtInOverride(id: shipped.id))
        _task = State(initialValue: effective.systemPrompt)
        _revision = State(initialValue: effective.revisionPrompt ?? "")
    }

    private var sections: PromptSections {
        PromptSections(usesLLM: shipped.usesLLM, task: $task, revision: $revision)
    }

    /// Editor text → override: only fields that differ from the shipped
    /// default are stored (equal-to-default edits prune to "unmodified").
    private var draftOverride: PromptOverride {
        PromptOverride(
            systemPrompt: task == shipped.systemPrompt ? nil : task,
            revisionPrompt: revision == (shipped.revisionPrompt ?? "") ? nil : revision
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(shipped.name, systemImage: shipped.symbol).font(.headline)
                Spacer()
                if controller.isBuiltInModified(id: shipped.id) {
                    Text("Modified").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { sections }
            }
            HStack {
                Button("Cancel", action: dismiss)
                Button("Reset to Default") {
                    controller.setBuiltInOverride(id: shipped.id, nil)
                    task = shipped.systemPrompt
                    revision = shipped.revisionPrompt ?? ""
                }
                .disabled(!controller.isBuiltInModified(id: shipped.id))
                Spacer()
                Button("Save") {
                    if controller.setBuiltInOverride(id: shipped.id, draftOverride) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sections.overLimit)
            }
        }
        .padding()
        .frame(width: 480, height: 560)
    }
}

/// Create/edit a custom mode: name, LLM toggle, and the full prompt text —
/// task AND refinement instructions (013 US3).
struct CustomModeEditor: View {
    @Bindable var controller: DictationController
    let initial: Mode
    var dismiss: () -> Void

    @State private var mode: Mode
    @State private var revision: String

    init(controller: DictationController, initial: Mode, dismiss: @escaping () -> Void) {
        self.controller = controller
        self.initial = initial
        self.dismiss = dismiss
        _mode = State(initialValue: initial)
        _revision = State(initialValue: initial.revisionPrompt ?? "")
    }

    private var sections: PromptSections {
        PromptSections(usesLLM: mode.usesLLM, task: $mode.systemPrompt, revision: $revision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $mode.name)
            Toggle("Use LLM rewrite", isOn: $mode.usesLLM)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { sections }
            }
            HStack {
                Button("Cancel", action: dismiss)
                Spacer()
                Button("Save") {
                    var saved = mode
                    saved.revisionPrompt = revision.isEmpty ? nil : revision
                    if controller.upsertMode(saved) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mode.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || sections.overLimit)
            }
        }
        .padding()
        .frame(width: 480, height: 600)
    }
}
