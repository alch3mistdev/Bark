# Quickstart & Manual QA Matrix: Suggested Responses (015)

Automated coverage (365 tests) exercises every decision path against fakes.
This matrix is the **runtime** half of T041 — the OS-adapter behavior that
can't be unit-tested (constitution Quality Gates): real AX trees, the
non-activating key panel (research.md R3), Screen Recording TCC, and live
injection targets.

## Prerequisites

```bash
swift build            # MLX config (default Package.swift)
swift test             # expect all green
swift run Bark         # or scripts/make-app.sh for a bundled run
```

Settings ▸ Suggest → enable; Settings ▸ Models → LLM rewrite ON (first run
downloads ~2.5 GB). Grant Accessibility + Input Monitoring when prompted.

## Core loop (US1 / SC-001 / SC-006)

| # | Steps | Expect |
|---|-------|--------|
| 1 | Terminal.app frontmost, run a CLI agent until it asks a question; press F6 | Overlay near caret ≤1 s ("Reading screen…" → "Thinking…"); 3–4 single-line options + "Other…" ≤6 s warm; terminal keeps focus (its window stays active-colored) |
| 2 | Press `2` | Overlay hides; exactly option 2's text typed at the cursor (keystroke path); no Return pressed |
| 3 | Press F6, then arrows + Return | Highlight moves (wraps clamped); Return inserts highlighted row |
| 4 | Press F6, click a row with the mouse | Same insertion; Bark never activates (menu bar app stays background) |
| 5 | Press F6, press Esc | Overlay closes, nothing typed |
| 6 | Press F6 twice quickly | Second press dismisses (toggle) |
| 7 | Press F6, then click another app's window | Overlay dismisses on focus loss (resignKey) |

## Key-panel spike validation (R3 — gates the overlay design)

| # | Steps | Expect |
|---|-------|--------|
| 8 | While overlay is up, type `1234o` quickly | Keys land in the overlay ONLY — nothing leaks into the terminal |
| 9 | While overlay is up, check the frontmost app (e.g. menu bar title) | Still the target app, never Bark |
| 10 | Pick an option; watch where text lands | In the app that was frontmost at F6-press, at its caret |

If 8–10 fail on this macOS build: switch to the documented event-tap fallback (research.md R3).

## "Other…" + auto-submit (US2)

| # | Steps | Expect |
|---|-------|--------|
| 11 | F6 → press `O` → speak a sentence → pause | One utterance transcribed + injected via the normal pipeline; hands-free stops itself (HUD disappears; menu shows Ready) |
| 12 | Settings ▸ Suggest → auto-submit ON → F6 → pick option in Terminal | Text inserted, then a single Return fires it |
| 13 | Auto-submit ON → F6 → pick option, but cmd-tab away within the settle beat | Text may insert per focus guard, but NO Return posts after focus changed |
| 14 | Auto-submit ON → "Other…" dictation | Never posts Return |
| 15 | Auto-submit ON → Settings ▸ General routing = Copy to clipboard → pick option | Lands on clipboard only; no keystrokes, no Return |

## Context breadth (US3)

| # | Steps | Expect |
|---|-------|--------|
| 16 | Safari: focus a labeled "Address" field (with history ON and a past dictated address) → F6 | At least one candidate reflects the address from history |
| 17 | An app with a thin AX tree (e.g. some Electron apps) → F6 with Screen Recording NOT granted | Honest state; Settings ▸ Permissions shows a Screen Recording row with Grant/Open Settings |
| 18 | Grant Screen Recording → repeat 17 | OCR fallback kicks in; suggestions appear |
| 19 | Settings ▸ Suggest → external backend, point at a local Ollama (`http://localhost:11434/v1`, a pulled model) | Suggestions come from Ollama; warning copy visible in settings |
| 20 | Stop Ollama → F6 | Falls back to the local model (or an honest endpoint error if LLM off) |

## Refusals & failure honesty (FR-004 / FR-017)

| # | Steps | Expect |
|---|-------|--------|
| 21 | Focus a password field (e.g. Safari login) → F6 | "Not available here — a secure field is focused."; nothing read, nothing sent |
| 22 | Revoke Accessibility → F6 | Guidance state naming the permission |
| 23 | LLM off + local backend → F6 | Error pointing at Settings ▸ Models |
| 24 | Hold fn (dictation) and press F6 mid-dictation | Nothing happens; dictation unaffected |
| 25 | F6 in Terminal/iTerm2/VS Code/Safari (matrix apps) | Capture succeeds or degrades per app; no hang > deadline; record per-app notes |

## Evidence to capture (SC-002 / SC-005)

```bash
# No captured screen content on disk after a session of suggestions:
ls ~/Library/Application\ Support/Bark/          # only history.enc / speaker.enc (if opted in)
grep -r "screen_context" ~/Library/Application\ Support/Bark/ 2>/dev/null | wc -l   # 0
# History (if on) holds only picked suggestion text, empty transcript:
#   Settings ▸ History → inspect the "suggestion" rows.
# Both configs:
swift build && swift test                        # MLX
cp Package-lean.swift Package.swift && swift build && swift test && git checkout Package.swift
```
