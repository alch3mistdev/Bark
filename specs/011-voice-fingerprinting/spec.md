# Feature Specification: Voice Fingerprinting (Speaker Gate for Hands-Free)

**Feature Branch**: `011-voice-fingerprinting`

**Created**: 2026-06-20

**Status**: Draft

**Input**: User description: "Voice fingerprinting so that in continuous (hands-free) mode the system only acts on the primary user's voice — in a noisy room or where multiple people speak, it only takes the user; and someone trying to verbally instruct the system can't, unless they share the user's voice."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Enroll my voice (Priority: P1)

The user opts in to the speaker gate and records a short set of spoken phrases so the
app learns what their voice sounds like. The app confirms enrollment succeeded and
stores the resulting voiceprint privately on the device. The user can re-enroll or
delete the voiceprint at any time.

**Why this priority**: Nothing else works without an enrolled voiceprint. It is the
foundation the runtime gate depends on, and it is independently valuable: a user can
enroll, see it stored securely, and delete it — a complete, demonstrable slice.

**Independent Test**: Turn on the speaker gate, complete the guided enrollment, confirm
a "voiceprint saved" state, quit and relaunch, confirm the voiceprint persists, then
delete it and confirm it is gone. No runtime gating required to test this.

**Acceptance Scenarios**:

1. **Given** the speaker gate is off and no voiceprint exists, **When** the user enables
   the gate, **Then** they are guided to record the required number of short phrases.
2. **Given** the user has recorded all enrollment phrases, **When** enrollment completes,
   **Then** the app reports success and the voiceprint is stored privately on the device.
3. **Given** a recorded phrase is too short or too quiet to use, **When** the app evaluates
   it, **Then** the user is asked to re-record that phrase rather than failing the whole flow.
4. **Given** a voiceprint exists, **When** the user chooses "delete voiceprint", **Then** the
   stored voiceprint and its protection key are removed and the gate becomes inactive.
5. **Given** a voiceprint exists, **When** the user relaunches the app, **Then** the voiceprint
   is still available without re-enrollment.

---

### User Story 2 - Only my voice triggers hands-free dictation (Priority: P2)

With the gate enabled and a voiceprint enrolled, hands-free (continuous) dictation only
acts on speech that matches the enrolled user. When someone else speaks — a coworker,
the TV, a bystander, or someone trying to issue a verbal command — the app silently
declines to type their words and keeps listening for the user.

**Why this priority**: This is the headline outcome. It depends on US1 but delivers the
core value: the app stops acting on other people in a shared or noisy space.

**Independent Test**: With a voiceprint enrolled, start hands-free mode. Speak a phrase
yourself and confirm it is typed. Have a different person speak (or play a recorded voice
from another device) and confirm nothing is typed and the session keeps listening.

**Acceptance Scenarios**:

1. **Given** the gate is enabled and the enrolled user speaks, **When** an utterance ends,
   **Then** the cleaned text is injected as normal.
2. **Given** the gate is enabled and a different person speaks, **When** that utterance ends,
   **Then** no text is injected, a faint non-intrusive cue distinct from the success sound
   plays, and the session continues listening.
3. **Given** the gate is enabled, **When** a non-matching utterance is declined, **Then** the
   session is NOT stopped or put into an error state (declining other voices is normal).
4. **Given** the gate is enabled but no voiceprint is enrolled, **When** any utterance ends,
   **Then** text is injected as normal (the gate stays out of the way until set up).
5. **Given** the gate is enabled and the matching check cannot run (unavailable on this
   build, model not present, utterance too short, or an internal error), **When** an utterance
   ends, **Then** text is injected as normal (the user is never locked out of their own dictation).
6. **Given** push-to-talk (hold-to-talk) dictation, **When** the user dictates, **Then** the
   speaker gate does not apply (holding the key is already deliberate user intent).

---

### User Story 3 - Tune strictness and understand the limits (Priority: P3)

The user can adjust how strict the matching is for their environment, and the app clearly
communicates what the gate does and does not protect against, so expectations are honest.

**Why this priority**: Real rooms vary; a fixed strictness frustrates users (false rejections
of their own voice, or too many other voices getting through). Honest framing prevents users
from over-trusting the gate as a security control.

**Independent Test**: Change the strictness setting across its options and observe the
acceptance behavior shift. Read the in-app explanation and confirm it states the gate is a
convenience filter, not protection against a recording or imitation of the user's voice.

**Acceptance Scenarios**:

1. **Given** the gate is enabled, **When** the user opens its settings, **Then** they can choose
   among low / medium / high strictness, defaulting to medium.
2. **Given** a higher strictness, **When** ambiguous utterances are evaluated, **Then** fewer
   non-matching voices pass (at the cost of occasionally re-declining the user's own voice).
3. **Given** the gate settings, **When** the user reads the accompanying explanation, **Then** it
   plainly states the gate filters out *other* speakers but does NOT stop a recording or an
   imitation/clone of the user's own voice, and is not authentication.
4. **Given** the optional capability is not included in the running build, **When** the user opens
   settings, **Then** the gate controls are hidden rather than shown as broken.

---

### Edge Cases

- **Background noise with no clear speaker**: handled by existing voice-activity detection;
  the gate only evaluates utterances that already passed activity detection.
- **The user's voice changes** (cold, tired, different mic): may cause occasional false
  rejection; mitigated by strictness setting and easy re-enrollment.
- **Very short utterances** ("yes", "stop"): too little signal to judge reliably → treated as
  unverifiable and allowed through (fail-open), not silently dropped.
- **Two people including the user speaking over each other**: out of scope to separate; the
  utterance is judged as a whole and may be accepted or declined.
- **Voiceprint becomes unreadable / incompatible** (e.g., the underlying matching model is
  later replaced): the stale voiceprint is treated as "not enrolled" and the user is prompted
  to re-enroll rather than being silently mis-judged.
- **Gate enabled but enrollment never finished**: treated as not enrolled → fail-open.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The speaker gate MUST be opt-in and OFF by default; the rest of the app behaves
  exactly as today when it is off.
- **FR-002**: The system MUST let the user enroll their voice by recording a small set of short
  spoken phrases, and MUST confirm when a usable voiceprint has been created.
- **FR-003**: The system MUST reject individual enrollment recordings that are too short or too
  quiet to be usable and prompt the user to re-record only those, without discarding good ones.
- **FR-004**: The system MUST store the enrolled voiceprint privately on the device, protected
  at rest, and MUST NOT transmit it off the device.
- **FR-005**: The system MUST let the user delete their voiceprint, removing both the stored data
  and its protection key, after which the gate is inactive.
- **FR-006**: When the gate is enabled and a voiceprint is enrolled, in hands-free mode the system
  MUST evaluate each completed utterance and inject text only if it matches the enrolled user.
- **FR-007**: When an utterance does not match, the system MUST NOT inject text, MUST play a faint
  cue distinct from the success sound, and MUST continue the hands-free session.
- **FR-008**: The speaker gate MUST apply to hands-free (continuous) mode only and MUST NOT alter
  push-to-talk behavior.
- **FR-009**: The system MUST fail open: if no voiceprint is enrolled, the matching capability is
  unavailable in the build, the required model is missing, the utterance is too short to judge, or
  an internal error occurs, the utterance MUST be injected as normal.
- **FR-010**: The system MUST let the user choose matching strictness among at least three levels
  (low / medium / high), defaulting to medium.
- **FR-011**: The system MUST present an honest description stating the gate filters out other
  speakers but does not protect against a recording, imitation, or clone of the user's own voice,
  and is not an authentication or liveness control.
- **FR-012**: All speaker-gate processing (enrollment and matching) MUST run on-device with no
  network access at runtime, consistent with the project's offline-first principle.
- **FR-013**: When the optional matching capability is not present in the running build, the gate's
  controls MUST be hidden rather than shown as nonfunctional.
- **FR-014**: Declining a non-matching utterance MUST NOT be treated as an error and MUST NOT stop
  the session or surface a failure message.

### Key Entities *(include if feature involves data)*

- **Voiceprint (Speaker Profile)**: A compact representation of the enrolled user's voice derived
  from their enrollment recordings, plus metadata (number of samples used, when enrolled, and a
  version tag identifying which matching model produced it). Stored privately on-device, protected
  at rest. There is exactly one per user/device.
- **Utterance**: A single span of speech captured in hands-free mode between detected start and end
  of speech. Each utterance is the unit that is matched against the voiceprint.
- **Strictness Setting**: The user-chosen level (low / medium / high) that controls how close a
  match must be before an utterance is accepted.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can complete voice enrollment in under 2 minutes on first attempt.
- **SC-002**: With the gate enabled, the enrolled user's own speech is accepted in a quiet room at
  least 95% of the time at the default strictness.
- **SC-003**: With the gate enabled, speech from a different person or a played-back recording of a
  different person is declined the large majority of the time at the default strictness (target:
  ≥80% in a quiet room; calibrated and reported with real captures before release).
- **SC-004**: Enabling the gate adds no perceptible delay to hands-free dictation of the user's own
  voice (no user-noticeable increase in time-to-text versus the gate off).
- **SC-005**: With the gate off, on a build without the capability, or before enrollment, behavior is
  identical to today (zero regressions in hands-free or push-to-talk dictation).
- **SC-006**: 100% of the time, a missing/disabled/erroring gate results in the user's own dictation
  still being typed (no lockout).
- **SC-007**: The in-app explanation of the gate's limits is present and reviewed for accuracy before
  release (no overclaiming of security).

## Assumptions

- Single primary user per device; multi-user voiceprints are out of scope for v1.
- The matching capability ships in the same opt-in build path as the project's other optional
  on-device models; the lean default build omits it and hides the controls.
- "Convenience gate, not security" is an explicit product decision: anti-spoofing / replay /
  voice-clone detection and liveness are out of scope for v1.
- Hands-free mode's existing voice-activity detection continues to decide utterance boundaries; the
  gate consumes those utterances and does not replace activity detection.
- Reasonable defaults for enrollment (a small fixed number of short varied phrases, each at least
  ~1 second of voiced audio) and strictness (three levels, default medium) are acceptable; exact
  thresholds are calibrated on real device captures before release.
- The voiceprint is biometric-adjacent personal data and is given the same on-device, encrypted,
  device-only protection the project already applies to dictation history.
