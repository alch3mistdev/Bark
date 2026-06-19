import Foundation

/// Pure microphone-level meter: maps a linear RMS amplitude to a smoothed
/// 0...1 value for the HUD bar. Uses a dBFS floor (so quiet rooms read ~0) and
/// asymmetric smoothing (fast attack, slow release) so the bar feels responsive
/// but doesn't flicker. No audio I/O — driven by `VoiceActivityDetector.rms`.
public struct LevelMeter: Sendable, Equatable {
    public var floorDB: Float
    public var attack: Float    // 0...1 smoothing toward a louder level
    public var release: Float   // 0...1 smoothing toward a quieter level
    private var value: Float = 0

    public init(floorDB: Float = -55, attack: Float = 0.6, release: Float = 0.18) {
        self.floorDB = floorDB
        self.attack = attack
        self.release = release
    }

    public var level: Float { value }

    /// Feed one frame's RMS; returns the new smoothed 0...1 level.
    public mutating func update(rms: Float) -> Float {
        let target = LevelMeter.normalize(rms: rms, floorDB: floorDB)
        let coeff = target > value ? attack : release
        value += (target - value) * coeff
        if value < 0.0005 { value = 0 }   // settle to a clean zero
        return value
    }

    public mutating func reset() { value = 0 }

    /// Linear RMS → 0...1 over `[floorDB, 0] dBFS`. rms≤0 → 0; ≥0 dBFS → 1.
    public static func normalize(rms: Float, floorDB: Float = -55) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        if db <= floorDB { return 0 }
        if db >= 0 { return 1 }
        return (db - floorDB) / -floorDB   // floorDB..0 → 0..1
    }
}
