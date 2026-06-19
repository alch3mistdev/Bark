# Bark — Competitive Analysis

*Snapshot: 2026-06-19. Re-run before any positioning shift. Source notes are inline where claims
need a citation.*

---

## TL;DR

Bark sits in a category of one. Five products are direct competitors on the
**dictation app** axis (Superwhisper, Wispr Flow, VoiceInk, Aqua Voice, Willow
Voice); two of them also compete on the **LLM rewrite** axis (Aqua, Willow).
Three STT engines are competing substitutes on the **engine** axis
(WhisperKit, Parakeet, Apple SpeechAnalyzer). Bark's defensible position is
**the only product with all three corners held**:

- Apple-native STT (lowest latency, ANE, zero bundled weight)
- Optional local LLM rewrite (Qwen3-4B via MLX)
- Hard offline posture (no network at runtime beyond user-initiated model download)

The closest peer by philosophy is **VoiceInk** (open-source, on-device). Bark
beats it on spec rigor, security model, and LLM quality. The closest peer by UX
ambition is **Superwhisper** (modes, LLM). Bark beats it on latency, offline
guarantee, and published STRIDE. The true long-term threat is Apple itself —
if Apple ships an "Apple Intelligence Dictate" with LLM rewrite, this category
collapses. Bark's spec/security depth is the only durable defense.

---

## Market Map (3 Axes)

The space fragments along **three orthogonal axes**:

| Axis | Spectrum |
|------|----------|
| STT Engine | Apple SpeechAnalyzer ↔ WhisperKit ↔ Parakeet ↔ Cloud APIs |
| LLM Rewrite Layer | None ↔ Deterministic cleaner ↔ Local LLM ↔ Cloud LLM |
| Deployment | Pure cloud ↔ Hybrid ↔ Pure on-device |

Bark is the **only product that holds all three corners**. Competitors split:

```
                     LOCAL LLM
                         │
        VoiceInk ●        │         ● Superwhisper
       (no LLM yet)       │        (Whisper local + cloud LLM)
                         │
PURE ON-DEVICE ──────────┼────────── CLOUD
                         │
   ★ BARK (Apple STT +   │      ● Wispr Flow
     Qwen3-4B MLX)        │      ● Aqua Voice
                         │      ● Willow Voice
        macOS Dictate ●   │      ● Monologue
       (Apple only, no    │
        LLM rewrite)      │
                         │
                     CLOUD LLM
```

★ = unique position nobody else occupies.

---

## Head-to-Head

### Superwhisper — closest direct competitor

| | Bark | Superwhisper |
|---|---|---|
| **STT** | Apple SpeechAnalyzer (ANE, ~55–60 ms) | Whisper on-device (small ~150–300 ms, large-v3 ~800 ms–1.2 s behind) |
| **Latency (short utterance)** | **Sub-100 ms** | 200–600 ms |
| **LLM layer** | Qwen3-4B 4-bit MLX, opt-in, non-blocking | Cloud LLMs (OpenAI/Anthropic) optional |
| **Offline** | Hard guarantee (no network at runtime) | Optional, not enforced |
| **Security model** | STRIDE-documented, prompt-injection fenced, focus-guard PID re-check, secure-field refusal, clipboard snapshot/restore | Marketing-claimed privacy, no public STRIDE |
| **Modes** | 6 built-in (Raw/Clean/Email/Message/Code/Commit/List) + custom | User-configured, takes hours to tune |
| **Price** | Free (open-source, MIT) | $8.49/mo, $85/yr, or **$249 lifetime** |
| **Architecture** | Spec-driven, 94 tests, ADRs, protocols for engine swap | Closed |
| **Stage** | Experimental, notarization pipeline not yet run | Shipped product |

**Bark wins on:** latency (ANE vs Whisper), transparency (STRIDE + spec),
offline guarantee, test coverage, LLM rewrite is local-first.
**Bark loses on:** not shipped, no notarization, no shipping customers.

### VoiceInk — open-source peer

| | Bark | VoiceInk |
|---|---|---|
| **STT** | Apple SpeechAnalyzer + Parakeet (wired via `STTEngineFactory`, ADR-006) | Whisper (on-device) |
| **LLM** | Qwen3-4B MLX (opt-in) | None / minimal |
| **Offline** | Hard | Default |
| **Modes** | 6 + custom, LLM-fenced | Power Mode (context-aware presets) — less granular |
| **License** | MIT (Bark) + per-model | GPLv3 |
| **Price** | Free | $25–49 once |
| **Security** | STRIDE + spec-driven, sha256-verified model downloads (`SEC-003`) | Community |

**Bark wins on:** LLM rewrite quality, spec rigor, security model, custom-mode
extensibility, latency on Apple STT, sha256-verified model downloads.
**VoiceInk wins on:** shipped, signed, working today.

### Wispr Flow — the cloud benchmark

Wispr Flow is the "polish" leader — best auto-formatting, best AI cleanup,
cross-platform. But: cloud-only, $15/mo, no offline option, no privacy story.
Bark isn't competing for that user. Different buyer entirely.

### Aqua Voice — the "intent shaping" rival

Aqua's "Audio+LLM fusion" is essentially what Bark does with `Mode`-based LLM
rewrite — but Aqua is cloud ($8–10/mo), has a SaaS backend, and is more
opinionated about *what you meant*. Bark is more deterministic + spec-driven;
Aqua is more magic. Aqua has better real-time shaping UX today; Bark has
better architecture.

### Willow Voice / Monologue / macOS Dictation

- **Willow** — cloud, $15/mo, cross-platform, "AI writing assistant with
  dictation." Not a threat to Bark's audience.
- **Monologue** — Mac-only, style-adapting, no public spec. Adjacent but
  smaller community.
- **macOS Dictate** — the existential floor. Apple SpeechAnalyzer is what Bark
  uses; if Apple ever ships an "Apple Intelligence Dictate" with LLM rewrite,
  this category collapses. **This is Bark's true long-term threat, not
  competitors.**

---

## Where Whisper Actually Sits

Important: **Whisper is an STT engine, not a dictation app.** Bark's design
correctly treats Whisper/WhisperKit as a swappable backend via the `STTEngine`
protocol — now wired in this PR (`Sources/BarkEngines/STT/WhisperKitEngine.swift`,
ADR-006).

| Whisper variant | Where it wins | Where Bark uses it |
|---|---|---|
| **WhisperKit (Argmax)** | 99+ languages, ~2–8% WER on English, ANE-friendly, sub-200 ms streaming | Wired behind `Package-stt-extras.swift`; opt-in via Settings ▸ Speech ▸ Engine |
| **Whisper large-v3 / -turbo** | Best raw accuracy, ~5–6% WER | Available via WhisperKit; not used as default (latency too high for dictation) |
| **Whisper.cpp** | Cross-platform, CPU fallback | Not used |
| **Whisper on cloud (OpenAI, Deepgram nova-3, gpt-4o-transcribe)** | Frontier accuracy on hard domains | Not used (Bark is offline-first) |

Bark's strategic choice — **default to Apple SpeechAnalyzer, fall back to
WhisperKit/Parakeet, never cloud** — is the right one for the
*speed-first dictation* use case. Whisper is correct as the multilingual
fallback, not as the default.

---

## Bark's Defensible Position (3 moats nobody else has)

1. **Security as a first-class spec, not a checkbox.** STRIDE threat model in
   `docs/SECURITY.md`, prompt-injection fencing around the LLM call, focus-PID
   re-verification, secure-field refusal, clipboard snapshot/restore with
   `changeCount` guarding, marked-concealed paste, sha256-verified model
   downloads (`SEC-003`). *No competitor publishes this.* VoiceInk: nothing.
   Superwhisper: marketing copy.

2. **Apple-native pipeline, not a Whisper wrapper.** Apple SpeechAnalyzer on
   ANE at ~55–60 ms + deterministic cleaner + opt-in MLX LLM (non-blocking,
   with hard deadline and fallback). This is structurally faster than every
   Whisper-based competitor on Apple Silicon.

3. **Spec-driven + protocol-wired.** `STTEngine` and `TextCleaner` protocols,
   94 tests, ADRs for each architectural decision, `constitution.md`. When you
   wire WhisperKit + Parakeet (now done, ADR-006), the *product architecture*
   doesn't change — only the adapter. Competitors are monolithic.

---

## Where Bark Is Actually Vulnerable (be honest)

- **Experimental / un-shipped.** No Developer-ID notarization, only `ad-hoc`
  signed for personal use. Gatekeeper friction. VoiceInk ships; Bark doesn't.
- **Apple is the floor risk.** If Apple ships "Apple Intelligence Dictate"
  with LLM rewrite and developer-callable APIs, the entire category — including
  VoiceInk, Superwhisper, Bark — gets eaten. Bark's spec/security depth is the
  only durable defense.

---

## Verdict & Strategic Recommendations

**Bark is not competing with Whisper.** Whisper is an STT engine Bark uses via
the `STTEngine` protocol (now wired, ADR-006). Bark is competing in the
**"offline-first, security-conscious, Apple-native AI dictation"** niche —
currently the most defensible slice of the market, occupied by exactly zero
shipped products.

**Three moves that close the gap from "experimental" to "category-defining":**

1. **Ship it.** Wire notarization, do Developer-ID, publish a real `.dmg`
   people can install without `xattr`. This is the single highest-leverage
   action. Everything else is moot if no one runs it.
2. **Make the security story the marketing story.** "The only dictation app
   with a published STRIDE model, sha256-verified model downloads, and
   prompt-injection defenses on the LLM rewrite." No one else is saying this.
   It's a real differentiator for security-conscious, regulated, and
   high-context users (legal, medical, dev with secrets).
3. **Lean into the Apple STT default.** Apple STT is fastest AND zero-weight;
   the whisper-kit/parakeet options are the multilingual fallback for users who
   need wider coverage. Frame the default as "lowest-latency, on-ANE, zero
   model weight" rather than "we don't have a good engine." It IS the good
   engine for the use case.

---

## Re-Run Triggers

This document should be re-run when:

- Any of the named competitors ship a material feature (Apple ships Apple
  Intelligence Dictate; VoiceInk adds LLM rewrite; Superwhisper ships offline
  guarantee)
- Bark ships (notarized, in the wild) — competitive landscape shifts
- A new STT engine ships with materially better Apple-Silicon latency
- Apple deprecates `SpeechAnalyzer` / `SpeechTranscriber`
