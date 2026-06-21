# Data Model: Voice Fingerprinting (Speaker Gate)

All types live in `Sources/BarkCore/Speaker/` (pure, `Sendable`, zero third-party deps) except the
encrypted store (BarkEngines). Persisted types use the project's tolerant-decode discipline.

## SpeakerEmbedding

A fixed-dimension voice vector.

| Field | Type | Notes |
|---|---|---|
| `values` | `[Float]` | 256-d for WeSpeaker v2. Expected L2-normalized for similarity math. |

**Behavior (pure, static where possible)**
- `l2normalized() -> SpeakerEmbedding` — unit-length; no-op-safe on a zero vector (returns zeros).
- `static cosineSimilarity(_ a: SpeakerEmbedding, _ b: SpeakerEmbedding) -> Float` — dot product of
  normalized vectors; range −1…1. Returns 0 if dimensions differ or either is empty (never crashes).
- `static mean(of: [SpeakerEmbedding]) -> SpeakerEmbedding` — element-wise average then re-normalize =
  enrollment centroid. Precondition: non-empty, equal dimensions (validated by caller in enrollment).

**Validation**: dimension must be > 0 and consistent across operands; mismatches degrade to a safe
0-similarity rather than throwing (keeps the gate fail-open).

`Codable, Sendable, Equatable`.

## SpeakerProfile

The enrolled voiceprint persisted on device. Exactly one per device.

| Field | Type | Notes |
|---|---|---|
| `centroid` | `SpeakerEmbedding` | Mean of enrollment-sample embeddings (normalized). |
| `sampleCount` | `Int` | Number of phrases used (target 5). |
| `enrolledAt` | `Date` | When created. |
| `modelID` | `String` | Embedding-model/version tag. A mismatch with the running model ⇒ profile treated as **not enrolled** (prompt re-enroll), never silently mis-scored. |

`Codable, Sendable, Equatable`. Persisted by `SpeakerProfileStore` (encrypted). No raw enrollment audio
is retained.

## SpeakerVerificationSensitivity

User-chosen strictness. Mirrors `VADSensitivity` exactly.

```
enum SpeakerVerificationSensitivity: String, Sendable, CaseIterable, Codable, Identifiable {
  case low, medium, high
  var acceptThreshold: Float   // cosine similarity; start 0.40 / 0.50 / 0.62 (calibrated before release)
  var label: String            // e.g. "Low (lenient)" / "Medium" / "High (strict — shared rooms)"
}
```

Default `.medium`. Higher = stricter = more false-rejects of the user, fewer other voices accepted.

## SpeakerDecision

Result of evaluating one utterance. Drives the gate branch.

| Case | Meaning | Gate action |
|---|---|---|
| `accept(score: Float)` | similarity ≥ threshold | inject |
| `reject(score: Float)` | similarity < threshold (gate ran) | **suppress** injection, faint cue, keep listening |
| `borderline(score: Float)` | just below threshold (within a small margin) | treated as reject for gating; score logged locally for calibration |
| `tooShort` | utterance below the voiced-duration floor | inject (fail-open) |
| `notEnrolled` | no usable profile (none / disabled / model-incompatible) | inject (fail-open) |

`Sendable, Equatable`. Note: `borderline` exists for local calibration logging only; it gates identically
to `reject`. Embedder errors are handled at the call site as fail-open (not a `SpeakerDecision` case).

## SpeakerVerifier (pure decision)

```
struct SpeakerVerifier {
  func decide(utterance: SpeakerEmbedding,
              profile: SpeakerProfile?,
              threshold: Float,
              borderlineMargin: Float = 0.05) -> SpeakerDecision
}
```

- `profile == nil` ⇒ `.notEnrolled`.
- else `score = cosineSimilarity(utterance, profile.centroid)`; `score ≥ threshold` ⇒ `.accept`;
  `score ≥ threshold − margin` ⇒ `.borderline`; else `.reject`.
- `tooShort` is decided **before** embedding (by the caller checking voiced duration), not inside `decide`.

Pure, total, no I/O — fully unit-testable in the lean build.

## Settings additions

In `Sources/BarkCore/Settings/Settings.swift`, two fields via the existing `decodeIfPresent` tolerant
pattern (old payloads default cleanly):

| Field | Type | Default | Notes |
|---|---|---|---|
| `speakerGateEnabled` | `Bool` | `false` | Opt-in, like `historyEnabled`/`llmEnabled`. |
| `speakerSensitivity` | `SpeakerVerificationSensitivity` | `.medium` | Strictness. |

## State / lifecycle

- **Enrollment**: `idle → recording(n of 5) → (per-take: usable | redo) → centroid built → profile saved`.
- **Profile**: `absent → enrolled → (deleted → absent) | (re-enrolled → enrolled)`.
- **Per-utterance gate** (hands-free only): `utterance finalized → [gate enabled & enrolled & model ready
  & ≥1.0s?] → embed → decide → accept→inject | reject→suppress+cue | else→inject(fail-open)`.

## Relationships

```
SpeakerProfile 1—1 SpeakerEmbedding (centroid)
SpeakerEnrollmentController →(produces)→ SpeakerProfile →(persisted by)→ SpeakerProfileStore
DictationController.runHandsFree →(uses)→ SpeakerEmbedder + SpeakerVerifier + SpeakerProfile + sensitivity.acceptThreshold
```
