import Foundation

/// A dictation "mode" = how raw speech is turned into the text that gets typed.
///
/// Two layers, both optional and independent:
///  - A deterministic pass (`BasicTextCleaner`) controlled by the flags below —
///    instant, no model, always safe.
///  - An LLM rewrite (`usesLLM == true`) driven by `systemPrompt` for reformatting
///    (email / message / code). The LLM stage never blocks delivery (ADR-003).
public struct Mode: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var name: String
    public var symbol: String          // SF Symbol name for the menu
    public var usesLLM: Bool
    public var systemPrompt: String    // instruction for the rewrite; ignored when usesLLM == false
    /// Per-mode refine/revision prompt for the second stage (012) — shared with
    /// feature 009. `nil` → the generic refine prompt. Optional + synthesized
    /// Codable decode it leniently, so older persisted custom modes load fine.
    public var revisionPrompt: String?

    // Deterministic-pass toggles.
    public var stripFillers: Bool
    public var smartCapitalize: Bool
    public var applySpokenPunctuation: Bool
    public var fixSpacing: Bool

    public init(
        id: String,
        name: String,
        symbol: String = "text.cursor",
        usesLLM: Bool = false,
        systemPrompt: String = "",
        revisionPrompt: String? = nil,
        stripFillers: Bool = true,
        smartCapitalize: Bool = true,
        applySpokenPunctuation: Bool = true,
        fixSpacing: Bool = true
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.usesLLM = usesLLM
        self.systemPrompt = systemPrompt
        self.revisionPrompt = revisionPrompt
        self.stripFillers = stripFillers
        self.smartCapitalize = smartCapitalize
        self.applySpokenPunctuation = applySpokenPunctuation
        self.fixSpacing = fixSpacing
    }
}

public extension Mode {
    /// Paste exactly what was said — no cleanup, only safety sanitization.
    static let raw = Mode(
        id: "raw", name: "Raw", symbol: "waveform",
        usesLLM: false,
        stripFillers: false, smartCapitalize: false,
        applySpokenPunctuation: false, fixSpacing: false
    )

    /// Default: instant deterministic cleanup (fillers, punctuation, casing).
    static let clean = Mode(
        id: "clean", name: "Clean", symbol: "sparkles",
        usesLLM: false
    )

    static let email = Mode(
        id: "email", name: "Email", symbol: "envelope",
        usesLLM: true,
        systemPrompt: "Rewrite the dictated text as a clear, well-punctuated email body. "
            + "Keep the author's meaning and facts exactly; do not add greetings, sign-offs, or invented details. "
            + "Fix grammar and structure into proper sentences and paragraphs.",
        revisionPrompt: "Apply the user's instruction while keeping an email register: "
            + "professional and concise; no greetings or sign-offs."
    )

    static let message = Mode(
        id: "message", name: "Message", symbol: "bubble.left",
        usesLLM: true,
        systemPrompt: "Rewrite the dictated text as a concise, natural chat message. "
            + "Keep it casual and faithful to the meaning; no greetings or sign-offs; do not add content."
    )

    static let code = Mode(
        id: "code", name: "Code / Commit", symbol: "chevron.left.forwardslash.chevron.right",
        usesLLM: true,
        systemPrompt: "Rewrite the dictated text as a clear, terse engineering note (code comment or commit message). "
            + "Preserve all technical terms, identifiers, and symbols verbatim. Imperative mood. Do not add content.",
        revisionPrompt: "Apply the user's instruction while preserving code identifiers and symbols "
            + "exactly; imperative and terse.",
        smartCapitalize: false
    )

    static let list = Mode(
        id: "list", name: "Bullet List", symbol: "list.bullet",
        usesLLM: true,
        systemPrompt: "Rewrite the dictated text as a tight bullet list (one '- ' item per point). "
            + "Keep meaning exactly; do not add items that were not said."
    )

    static let builtInModes: [Mode] = [.raw, .clean, .email, .message, .code, .list]
}

/// Holds the active set of modes (built-ins + user customs) and the current selection.
public struct ModeRegistry: Sendable, Equatable {
    public private(set) var modes: [Mode]
    public var selectedID: String

    public init(modes: [Mode] = Mode.builtInModes, selectedID: String = Mode.clean.id) {
        self.modes = modes
        self.selectedID = modes.contains(where: { $0.id == selectedID }) ? selectedID : (modes.first?.id ?? Mode.clean.id)
    }

    public var selected: Mode {
        modes.first(where: { $0.id == selectedID }) ?? .clean
    }

    public func mode(id: String) -> Mode? {
        modes.first(where: { $0.id == id })
    }

    public mutating func select(_ id: String) {
        guard modes.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Add or replace a custom mode by id.
    public mutating func upsert(_ mode: Mode) {
        if let idx = modes.firstIndex(where: { $0.id == mode.id }) {
            modes[idx] = mode
        } else {
            modes.append(mode)
        }
    }

    public mutating func remove(id: String) {
        guard !Mode.builtInModes.contains(where: { $0.id == id }) else { return } // can't delete built-ins
        modes.removeAll { $0.id == id }
        if selectedID == id { selectedID = Mode.clean.id }
    }
}
