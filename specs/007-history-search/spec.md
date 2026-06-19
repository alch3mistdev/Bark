# Feature Specification: History search + re-insert

**Branch**: `007-history-search` | **Created**: 2026-06-19 | **Status**: Draft
**Input**: Search/filter saved history and re-use a past dictation in one click (roadmap plan, scope
"top 3 quick wins"). Depends on 006's `ClipboardInjector` for the safe re-insert path.

## User Scenarios

### US1 — Search history (P1)
With history enabled, the user types in a search box in Settings and the list filters to matching
dictations (case/diacritic-insensitive over transcript + output). A blank box shows recent items.

**Acceptance**:
1. Typing "git" shows only records whose transcript or output contains "git" (any case, ignoring accents).
2. Clearing the box restores the recent list (newest-first, trimmed by retention policy).
3. A query with no matches shows "No matches" (not "No history").

### US2 — Re-use a past dictation (P1)
The user re-uses a stored dictation in one click.

**Acceptance**:
1. From the **Settings window**, "Copy" places the record's output on the clipboard (concealed marker; no
   typing) — safe because Settings is frontmost and typing would land in the wrong place.
2. From the **menubar popover** ("Re-insert recent"), selecting an item types it into the app that was
   frontmost, honouring the focus/secure-field guards and the global output routing.
3. Re-insert is a no-op while a dictation session is active.

## Success Criteria
- Pure `HistoryQuery.filter` unit-tested (substring, case/diacritic-insensitive, mode/app facets, empty→all).
- `HistoryStore.search`/`recent` as default protocol extensions (no concrete-store change), tested against
  the encrypted store. Controller `searchHistory` / `copyToClipboard` / `reinsert`. `swift build` clean,
  `swift test` green.
