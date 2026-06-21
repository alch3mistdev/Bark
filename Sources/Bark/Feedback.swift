import AppKit

/// Subtle system-sound cues for dictation start/insert. Gated by
/// `Settings.soundFeedback`. The "started" cue is played as a pre-roll just
/// before the mic opens (so it isn't captured), and "inserted" after the text
/// is placed.
enum Feedback {
    @MainActor static func started() { play("Tink") }
    @MainActor static func inserted() { play("Pop") }

    /// Faint, non-intrusive cue when the speaker gate declines a non-matching
    /// voice — deliberately distinct from the "inserted" success sound (FR-007).
    @MainActor static func declined() { play("Morse") }

    @MainActor private static func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
}
