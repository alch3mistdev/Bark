# Research: Streaming Suggested Responses (016)

No NEEDS CLARIFICATION markers existed in the Technical Context; research resolves design choices.

## R1 — Streaming seam: defaulted protocol extension, not a new protocol

**Decision**: Add `suggestStream(_ request:) -> AsyncThrowingStream<String, Error>` to `SuggestionEngine` with a default implementation that calls `suggest(_:)` and yields the whole result as one terminal chunk.

**Rationale**: Existing conformers (`OpenAICompatClient`, test fakes) compile and behave unchanged — the default *is* the FR-010 graceful degrade. The controller can talk to one seam unconditionally; "can this backend stream?" stops being a question anyone asks. Matches constitution Principle III (pipeline depends on the protocol only).

**Alternatives considered**: A separate `StreamingSuggestionEngine` protocol with runtime downcast — rejected: two seams, casts in the controller, and fakes must pick a side. A capability flag (`var supportsStreaming`) — rejected: the default-impl approach makes the flag's false branch structurally identical to the flag not existing.

## R2 — External endpoint stays non-streaming in v1

**Decision**: `OpenAICompatClient` keeps the default (batch) `suggestStream`. No SSE.

**Rationale**: SSE chat-completions streaming adds a second wire format (event framing, `[DONE]` sentinel, per-provider quirks) for a backend that is opt-in and already network-bound; the latency win there is dominated by network + provider TTFT, not by our display policy. Prewarm and early-overlay still apply. Fail-toward-local (015 R8) stays trivially correct because the fallback path re-enters the same streaming loop with the local engine.

**Alternatives considered**: Implement SSE now — rejected as scope creep; the contract file documents how it would slot in (implement `suggestStream` natively in the client; nothing else changes).

## R3 — Incremental parsing: prefix-stable extraction sharing 015's validation

**Decision**: New pure `SuggestionStreamParser` (struct, `mutating func consume(_ chunk: String) -> [String]`, `mutating func finish() -> [String]`). It accumulates raw text and emits a candidate only when it is *provably complete*:

- Think blocks: text inside `<think>`/`<reasoning>` spans is held back until the closing tag arrives; an unterminated span at `finish()` is dropped (matches batch behavior).
- JSON-array format: once a `[` that starts a decodable string array is seen (outside think spans), each *closed* top-level string literal (quote/escape aware, matching the batch parser's balanced scan) is a completed candidate; the array closes at its balanced `]`.
- Marked-line format (salvage): a line starting with the 015 markers (`-`, `*`, `•`, `–`, `1.`, `1)`) completes when its `\n` arrives; at `finish()`, the last unterminated line completes if the stream ended cleanly.
- Every completed candidate passes through the *same* validation as the batch parser (trim, length cap, non-empty, dedupe against already-emitted, candidate cap) before being emitted. Validation is extracted from `SuggestionResponseParser` into a shared internal helper so there is exactly one rulebook.

**Parity guarantee (SC-002)**: emitted-so-far must always equal a prefix of `SuggestionResponseParser.parse(bufferSoFar)`'s output for the formats above. Enforced by a corpus test: every existing batch-parser test input, chunked at *every* split position (and a set of multi-split randomized-by-index cases), asserting incremental emissions + `finish()` == batch result exactly.

**Rationale**: Reusing the batch validator is what makes "streaming changes when, never what" true by construction rather than by hope.

**Alternatives considered**: Re-running the batch parser on the growing buffer after every chunk and diffing — rejected: the batch parser's output for a *truncated* buffer can differ from its output for the final buffer (e.g. salvage kicks in before the array's `[` arrives), which would show candidates that later "shouldn't exist"; candidates are immutable once shown, so extraction must be conservative, not speculative.

## R4 — Session machine: incremental events replace the batch event

**Decision**: `SuggestionEvent.candidatesReady([String])` is replaced by `.candidateArrived(String)` (legal in `.generating` → first candidate moves phase to `.presenting`; legal in `.presenting` → append) and `.generationFinished` (legal in `.generating` — caller routes the zero-candidate case to `.errored` — and in `.presenting`, where it clears the new `isStreaming` flag). Numbering = array index at arrival, never recomputed. Highlight stability: if the highlight sits on the "Other…" row when a candidate arrives, it moves with the Other row (stays on Other); a highlight on a candidate row is untouched.

**Rationale**: The batch path becomes "N arrivals then finished" — one code path for streaming and degrade (SC-005). The event rename is safe: `SuggestionSession` is internal to the app + tests.

**Alternatives considered**: Keeping `.candidatesReady` alongside the new events — rejected: two ways to reach `.presenting` doubles the transition matrix for no caller benefit.

## R5 — Controller: split the generation task from the flow task

**Decision**: The streaming loop runs in its own `generationTask` (child of the pass, guarded by the existing `passToken`). `choose(_:)`, `chooseOther()`, `acceptHighlighted()` and `dismiss()` cancel `generationTask` first; injection then proceeds on `flowTask` exactly as today. Deadline: the existing `generationDeadline` wraps the whole stream; if it fires with ≥1 candidate shown the session just finishes (FR-011), with zero it surfaces the existing timeout error.

**Rationale**: Today `choose()` overwrites `flowTask` with the injection task — under streaming that would orphan a live generation loop which keeps publishing into a dismissed overlay. A dedicated handle makes cancel-before-inject an invariant (SC-003/SC-004). `passToken` still backstops engines that ignore cancellation.

**Alternatives considered**: Relying on `passToken` alone (let the orphan loop run to deadline, discarding output) — rejected: wastes battery/GPU on the local model and holds model residency longer than needed.

## R6 — Prewarm: already correct; lock it with tests

**Decision**: No behavior change. 015 already calls `dictation.prepareLLM()` in `start()` before the capture task launches (015 R2), i.e. preparation overlaps capture as US3 demands; secure-field refusal aborts the pass without generating (prepare has no side effects beyond model residency). Add instrumented-fake tests asserting (a) prepare begins before capture completes, (b) refusal ⇒ no `suggest`/`suggestStream` call ever happens.

**Rationale**: US3's value is a guarantee, not new code — the guarantee gets a regression test instead of a rewrite.

**Alternatives considered**: Moving prewarm even earlier (before `targetProvider()`) — rejected: the target probe is synchronous and sub-millisecond; reordering buys nothing and loses the "never suggest into Bark itself" early-out.

## R7 — Overlay: key from `.generating`, footer indicator, early "Other…"

**Decision**: The panel takes key at `.generating` (capture is complete by then — the R3 "never key during capture" constraint is untouched at `.capturing`). From `.generating` the view shows the "Other…" row (FR-012) plus a small "more coming…" footer (spinner + text) that persists through `.presenting` while `isStreaming`, disappearing on `.generationFinished`. Rows append below existing rows; panel grows top-anchored (existing resize logic already keeps the top-left corner fixed). `chooseOther` becomes legal from `.generating` (cancels generation, starts one-shot dictation).

**Rationale**: FR-012 requires an actionable overlay before the first candidate; that needs key status, which is safe exactly from the moment capture ends. The footer reuses the existing status-row visual language.

**Alternatives considered**: Keeping the panel non-key until first candidate — rejected: makes "Other…" dead until the model produces something, the opposite of the escape-hatch's purpose.
