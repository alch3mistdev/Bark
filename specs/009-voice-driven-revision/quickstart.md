# Bark — Voice-Driven Revision (Quickstart)

## What this adds

A second hotkey (default **⌥⌘R**) that revises what Bark *just* injected. Two modes:

- **Deterministic dictionary** — always available, even in the lean build (no LLM needed).
- **LLM-backed rewrite** — for free-form instructions like *"more formal"*, *"shorter"*,
  *"fix grammar"*. Available when the LLM is enabled.

Every revision produces a `HistoryRecord` linked to its parent, so the History pane can revert
the chain.

## Install (lean build — dictionary only)

```bash
swift build            # fully offline, no external dependencies
swift test             # 102 → ~120 tests, all green
scripts/make-dmg.sh    # build dist/Bark.dmg (ad-hoc signed)
open dist/Bark.dmg     # drag Bark to Applications
```

After install:

1. Launch Bark. Grant Microphone, Accessibility, Input Monitoring.
2. Open **Settings ▸ Hotkey**. Find **Revision hotkey** (default ⌥⌘R). Record a different
   key if you prefer.
3. Open **Settings ▸ General**. Confirm **Enable voice-driven revision** is on (default).

## Use (lean build)

1. Hold `fn` and dictate into any text field. Release.
2. Hold `⌥⌘R` and speak a command:
   - *"delete that"* / *"scratch that"* — deletes the just-injected text
   - *"undo"* — undoes the injection (system undo)
   - *"select all"* / *"select everything"* — selects all in the focused field
   - *"copy"* / *"copy that"* — copies the focused field's contents
3. Release. Bark performs the AX action; no LLM required.

## Use (with LLM — free-form revisions)

1. Enable the LLM: **Settings ▸ General ▸ Cleanup ▸ Use LLM rewrite**. Wait for
   *"Qwen3-4B ready"*.
2. Dictate something. Release.
3. Hold `⌥⌘R` and speak an instruction:
   - *"more formal"* — applies an email register (uses the Email revision prompt)
   - *"shorter"* — trims without losing meaning
   - *"fix grammar"* — corrects without changing voice
   - *"actually scratch that, say: I'll reply tomorrow"* — rewrites to the new text directly
4. Release. Bark revises the just-injected text in place and appends a linked History record.

## Per-mode revision prompts

The revision uses the prompt that matches the **mode you dictated in**, not your current mode:

| Mode you dictated in | Revision prompt behavior |
|---|---|
| Raw / Clean | Plain rewrite; preserve meaning |
| Email | Professional, concise register; preserve "Hi", "Best," etc. |
| Code | Preserve code identifiers verbatim (e.g. `viewDidLoad`); preserve formatting |
| Commit | Single-line subject unless you ask for a body |
| List | Comma-separated list |
| Custom | Your `revisionPrompt` field, or Clean's default if unset |

## Revert a revision chain

**Settings ▸ History** shows revisions as a *child of previous* badge. Tap any entry to re-insert
that exact text (re-runs the secure-field / focus-guard / sanitizer controls — refuses on
passwords and focus drift).

## When Bark refuses

- **"Refused: a password/secure field is focused."** — focused element is `AXSecureTextField` or
  Secure Input is active. Move focus to the field you want to revise and try again.
- **"Nothing to revise yet — dictate something first."** — no recent injection, or the previous
  injection targeted a different field. Dictate first, then revise.
- **"Window focus changed — text not inserted."** — focus drifted between your instruction and
  the rewrite. Bark preserved the original. Try again from a stable focus.
- **"Revision rejected."** — LLM output failed validation (length drift, banned characters, or a
  prompt-injection attempt). Bark preserved the original. Re-revise with a clearer instruction.
- **"Bark can't do that yet — turn on the LLM for free-form revisions."** — you spoke a
  non-dictionary phrase in the lean build. Enable the LLM, or use a dictionary command.

## Build flags

```bash
# Lean (no LLM, dictionary only):
swift build -c release

# With LLM (free-form revisions):
cp Package-mlx.swift Package.swift
swift build -c release
```

The revision feature works in **both** builds; the lean build gives you the deterministic
dictionary, the MLX build adds free-form revisions.

## Verification (manual, on-device only — see constitution L-5)

1. Open TextEdit. Dictate "thanks for the email ill get back to you tomorrow".
2. Revise: *"more formal"*. Expect: "Thank you for the email. I will be in touch tomorrow."
3. Revise again: *"shorter"*. Expect: "Thanks for your email; I'll be in touch tomorrow."
4. Open History. Expect three records, the latter two linked to the first.
5. Re-insert the second. Expect the original "more formal" version to overwrite the field.
6. Open 1Password's master-password field. Try to revise. Expect refusal.

## What this does NOT do

- **Multi-turn revision dialogs.** One revision per hotkey hold. Re-press to revise again.
- **Revise arbitrary text.** Bark only revises text it itself injected. Manually-typed text
  after the last injection is not revised; the operation acts on the last `HistoryRecord`.
- **Voice-controlled shell commands.** The dictionary covers delete / undo / copy / select-all.
  A full "voice-controlled commands" mode is a separate spec.