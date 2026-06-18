import XCTest
@testable import BarkCore

final class AudioRingBufferTests: XCTestCase {
    func testWriteThenReadIsFIFO() {
        let ring = AudioRingBuffer(capacity: 8)
        XCTAssertEqual(ring.write([1, 2, 3, 4]), 4)
        XCTAssertEqual(ring.availableToRead, 4)
        XCTAssertEqual(ring.read(maxCount: 4), [1, 2, 3, 4])
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testPartialRead() {
        let ring = AudioRingBuffer(capacity: 8)
        ring.write([10, 20, 30])
        XCTAssertEqual(ring.read(maxCount: 2), [10, 20])
        XCTAssertEqual(ring.read(maxCount: 2), [30])
        XCTAssertEqual(ring.read(maxCount: 2), [])
    }

    func testWraparoundPreservesOrder() {
        let ring = AudioRingBuffer(capacity: 4)
        XCTAssertEqual(ring.write([1, 2, 3]), 3)
        XCTAssertEqual(ring.read(maxCount: 2), [1, 2]) // tail now at 2
        XCTAssertEqual(ring.write([4, 5, 6]), 3)       // wraps across the end
        XCTAssertEqual(ring.read(maxCount: 4), [3, 4, 5, 6])
        XCTAssertEqual(ring.droppedSampleCount, 0)
    }

    func testOverflowDropsNewestAndCounts() {
        let ring = AudioRingBuffer(capacity: 4)
        XCTAssertEqual(ring.write([1, 2, 3, 4, 5]), 4) // only 4 fit
        XCTAssertEqual(ring.droppedSampleCount, 1)     // the 5 was dropped
        XCTAssertEqual(ring.read(maxCount: 10), [1, 2, 3, 4])
    }

    func testDrainEmptiesEverything() {
        let ring = AudioRingBuffer(capacity: 16)
        ring.write([1, 2, 3, 4, 5])
        XCTAssertEqual(ring.drain(), [1, 2, 3, 4, 5])
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertEqual(ring.drain(), [])
    }

    func testManyCyclesStayConsistent() {
        let ring = AudioRingBuffer(capacity: 5)
        var expected: Float = 0
        for _ in 0..<50 {
            ring.write([expected, expected + 1, expected + 2])
            let got = ring.read(maxCount: 3)
            XCTAssertEqual(got, [expected, expected + 1, expected + 2])
            expected += 3
        }
        XCTAssertEqual(ring.droppedSampleCount, 0)
    }
}
