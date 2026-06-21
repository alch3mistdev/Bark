# Contract: SpeakerVerifier + Sensitivity

Pure decision logic in `BarkCore` (no I/O, no deps). Fully unit-tested in the lean build.

## SpeakerVerifier

```swift
public struct SpeakerVerifier: Sendable {
    public init() {}

    public func decide(
        utterance: SpeakerEmbedding,
        profile: SpeakerProfile?,
        threshold: Float,
        borderlineMargin: Float = 0.05
    ) -> SpeakerDecision
}
```

**Semantics**
| Input condition | Output |
|---|---|
| `profile == nil` | `.notEnrolled` |
| `score ≥ threshold` | `.accept(score)` |
| `threshold − margin ≤ score < threshold` | `.borderline(score)` |
| `score < threshold − margin` | `.reject(score)` |

where `score = SpeakerEmbedding.cosineSimilarity(utterance, profile.centroid)`.

- Total and deterministic. No throwing. Dimension mismatch ⇒ `cosineSimilarity` returns 0 ⇒ `.reject`
  (the gate is enabled & enrolled here, so a degenerate embedding correctly fails closed *within* the
  gate; the surrounding fail-open paths handle not-enrolled / errors / tooShort upstream).
- `tooShort` is **not** produced here — the caller decides it before embedding (voiced-duration check).
- `borderline` gates identically to `reject`; it exists only so the caller can locally log near-misses
  for threshold calibration.

## SpeakerVerificationSensitivity → threshold

```swift
public enum SpeakerVerificationSensitivity: String, Sendable, CaseIterable, Codable, Identifiable {
    case low, medium, high
    public var id: String { rawValue }
    public var acceptThreshold: Float   // cosine similarity
    public var label: String
}
```

| Case | `acceptThreshold` (start) | `label` (illustrative) |
|---|---|---|
| `low`    | 0.40 | "Low (lenient)" |
| `medium` | 0.50 | "Medium" |
| `high`   | 0.62 | "High (strict — shared rooms)" |

Thresholds are **starting points**, calibrated on real device captures before release (research D3,
SC-007). Mirrors `VADSensitivity.energyThreshold` in shape and file location.

## Unit test obligations (BarkCoreTests)
- `cosineSimilarity`: identical vectors → 1.0; orthogonal → 0; opposite → −1; dimension mismatch → 0;
  empty → 0.
- `mean`: centroid of N identical vectors equals that vector (normalized); averaging is element-wise then
  renormalized.
- `decide`: accept / borderline / reject boundaries at exact threshold and ±margin; `nil` profile →
  `.notEnrolled`.
- sensitivity: each case maps to its documented threshold; `CaseIterable` covers all three.
