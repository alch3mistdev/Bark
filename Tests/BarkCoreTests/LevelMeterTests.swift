import XCTest
@testable import BarkCore

final class LevelMeterTests: XCTestCase {
    func testNormalizeFloorAndCeiling() {
        XCTAssertEqual(LevelMeter.normalize(rms: 0), 0)
        XCTAssertEqual(LevelMeter.normalize(rms: -1), 0)            // guard rms>0
        XCTAssertEqual(LevelMeter.normalize(rms: 1.0), 1, accuracy: 0.0001)  // 0 dBFS
        XCTAssertEqual(LevelMeter.normalize(rms: 2.0), 1, accuracy: 0.0001)  // clamps above 0 dB
    }

    func testNormalizeBelowFloorIsZero() {
        // -55 dBFS floor → rms ≈ 10^(-55/20) ≈ 0.00178; anything quieter reads 0.
        XCTAssertEqual(LevelMeter.normalize(rms: 0.0001, floorDB: -55), 0)
    }

    func testNormalizeMonotonic() {
        let a = LevelMeter.normalize(rms: 0.01)
        let b = LevelMeter.normalize(rms: 0.1)
        let c = LevelMeter.normalize(rms: 0.5)
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        for v in [a, b, c] { XCTAssertGreaterThanOrEqual(v, 0); XCTAssertLessThanOrEqual(v, 1) }
    }

    func testAttackRisesReleaseFalls() {
        var m = LevelMeter()
        let up1 = m.update(rms: 1.0)
        let up2 = m.update(rms: 1.0)
        XCTAssertGreaterThan(up2, up1)        // attack climbs toward 1
        XCTAssertLessThanOrEqual(up2, 1)
        // now go silent: level decays toward 0
        let down1 = m.update(rms: 0)
        let down2 = m.update(rms: 0)
        XCTAssertLessThan(down1, up2)
        XCTAssertLessThan(down2, down1)
    }

    func testSettlesToZero() {
        var m = LevelMeter()
        _ = m.update(rms: 1.0)
        for _ in 0..<200 { _ = m.update(rms: 0) }
        XCTAssertEqual(m.level, 0)
    }

    func testResetClearsLevel() {
        var m = LevelMeter()
        _ = m.update(rms: 1.0)
        m.reset()
        XCTAssertEqual(m.level, 0)
    }
}
