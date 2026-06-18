import Synchronization

/// Lock-free single-producer / single-consumer ring buffer of `Float` samples.
///
/// The realtime audio callback is the sole **producer** (`write`); a single
/// background consumer drains it (`read`). The producer only advances `head`,
/// the consumer only advances `tail` — so neither side ever blocks or locks
/// the other (mitigates ARCH-003: never block the realtime audio thread).
///
/// On overflow the **newest** overflowing samples are dropped (the producer
/// never mutates `tail`, preserving SPSC ownership) and counted in
/// `droppedSampleCount`. Under a consumer that keeps up, overflow never occurs.
public final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutableBufferPointer<Float>
    private let head = Atomic<Int>(0)   // total samples written (producer-owned)
    private let tail = Atomic<Int>(0)   // total samples read (consumer-owned)
    private let dropped = Atomic<Int>(0)

    public init(capacity: Int) {
        precondition(capacity > 0, "ring capacity must be positive")
        self.capacity = capacity
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        self.storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    public var capacitySamples: Int { capacity }

    /// Samples currently available to read.
    public var availableToRead: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .acquiring)
        return h - t
    }

    /// Total samples dropped due to overflow since creation.
    public var droppedSampleCount: Int { dropped.load(ordering: .relaxed) }

    /// PRODUCER ONLY. Writes up to `samples.count`; returns the number written.
    /// Any remainder is dropped (counted). No allocation, no locks.
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        let h = head.load(ordering: .relaxed)          // producer owns head
        let t = tail.load(ordering: .acquiring)        // observe consumer progress
        let free = capacity - (h - t)
        let n = min(samples.count, free)
        var i = 0
        while i < n {
            storage[(h + i) % capacity] = base[i]
            i += 1
        }
        if samples.count > n {
            dropped.wrappingAdd(samples.count - n, ordering: .relaxed)
        }
        head.store(h + n, ordering: .releasing)        // publish to consumer
        return n
    }

    /// PRODUCER ONLY convenience.
    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// CONSUMER ONLY. Reads up to `maxCount` samples. Returns the read samples.
    /// (Allocates the returned array — the realtime, alloc-free path is `write`.)
    public func read(maxCount: Int) -> [Float] {
        let t = tail.load(ordering: .relaxed)          // consumer owns tail
        let h = head.load(ordering: .acquiring)        // observe producer progress
        let n = min(maxCount, h - t)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = storage[(t + i) % capacity]
        }
        tail.store(t + n, ordering: .releasing)        // publish to producer
        return out
    }

    /// CONSUMER ONLY. Drains everything currently available.
    public func drain() -> [Float] {
        read(maxCount: availableToRead)
    }
}
