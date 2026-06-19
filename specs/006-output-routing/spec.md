# Feature Specification: Output routing / clipboard-only

**Branch**: `006-output-routing` | **Created**: 2026-06-19 | **Status**: Draft
**Input**: Let the user choose where dictated text goes — typed into the focused app (current) or copied
to the clipboard (roadmap plan, scope "top 3 quick wins"). Also the seam 007 reuses for safe re-insert.

## User Scenarios

### US1 — Choose output destination (P1)
The user picks a global output mode in Settings: "Type into the app" (default) or "Copy to clipboard".
When set to copy-only, finishing a dictation places the text on the clipboard and types nothing.

**Acceptance**:
1. With routing = Type into app, behaviour is unchanged: normal apps paste, terminals get keystrokes.
2. With routing = Copy to clipboard, the result lands on the clipboard (pasteable with ⌘V) and nothing is
   typed into the focused field; the focus/secure-field preflight is skipped (nothing is injected).
3. The clipboard payload is marked concealed (`org.nspasteboard.ConcealedType`) so clipboard managers can
   avoid logging it; the clipboard is not restored (leaving the result is the point).
4. Sound/insert feedback still fires; the result is still recorded to history (when enabled).

## Success Criteria
- Pure `InjectionRouter` unit-tested (copyOnly wins; terminal still keystroke when routing=insert).
- `ClipboardInjector` conforms to `TextInjector`; controller dispatches strategy via `InjectionRouter`.
- Settings GeneralPane picker; tolerant `Settings.outputRouting` decode. `swift build` clean, `swift test` green.
