import Foundation

/// Token buckets per key, in memory. Push runs as one instance (`max_instances = 1`), so this holds for
/// v1; a restart or a second instance forgets them, which only lets a few extra rings through.
///
/// At most `maxKeys` buckets are kept. When a new key arrives at the cap, the least recently used one is
/// forgotten (it starts full if it returns), so a flood of keys costs constant time per request and
/// bounded memory, and the keys in use stay.
public struct RateLimiter: Sendable {
    private struct Bucket: Sendable {
        var tokens: Double
        var updated: Date
        /// The bucket's latest entry in `recency`.
        var use: UInt64
    }

    /// The most requests in a burst; the bucket refills to this.
    public let capacity: Double
    /// Requests regained per second.
    public let refill: Double
    public let maxKeys: Int
    private var buckets: [String: Bucket] = [:]
    private var recency = RecencyQueue()

    public init(perMinute: Double, burst: Double? = nil, maxKeys: Int = 10_000) {
        capacity = burst ?? perMinute
        refill = perMinute / 60
        self.maxKeys = max(1, maxKeys)
    }

    /// Whether `key` may make a request now; takes one if so.
    public mutating func allow(_ key: String, now: Date) -> Bool {
        var bucket = buckets[key].map { refilled($0, now: now) } ?? Bucket(tokens: capacity, updated: now, use: 0)
        let allowed = bucket.tokens >= 1
        if allowed { bucket.tokens -= 1 }
        bucket.use = recency.append(key)
        buckets[key] = bucket
        while buckets.count > maxKeys, let oldest = recency.popOldest() {
            if buckets[oldest.key]?.use == oldest.use { buckets[oldest.key] = nil }
        }
        if recency.needsCompacting(keeping: maxKeys) {
            recency.keep(recency.entries.filter { buckets[$0.key]?.use == $0.use })
        }
        return allowed
    }

    /// Puts back a token taken for a request that never reached APNs.
    public mutating func refund(_ key: String) {
        guard var bucket = buckets[key] else { return }
        bucket.tokens = min(capacity, bucket.tokens + 1)
        buckets[key] = bucket
    }

    var count: Int { buckets.count }
    /// Entries in the recency queue, live or superseded.
    var tracked: Int { recency.entries.count }

    private func refilled(_ bucket: Bucket, now: Date) -> Bucket {
        let elapsed = max(0, now.timeIntervalSince(bucket.updated))
        return Bucket(tokens: min(capacity, bucket.tokens + elapsed * refill), updated: now, use: bucket.use)
    }
}

/// Call IDs Push already rang each device for, so a replayed or retried request rings once.
///
/// Every call is kept for the same `lifetime`, so the oldest entry expires first: expired calls are
/// dropped from the front as time passes, and at `maxKeys` the oldest goes early.
public struct CallMemory: Sendable {
    private struct Call: Sendable {
        var expiry: Date
        var use: UInt64
    }

    private var seen: [String: Call] = [:]
    private var recency = RecencyQueue()
    public let lifetime: TimeInterval
    public let maxKeys: Int

    public init(lifetime: TimeInterval, maxKeys: Int = 10_000) {
        self.lifetime = lifetime
        self.maxKeys = max(1, maxKeys)
    }

    /// Remembers `key`; false when it was already remembered and has not expired.
    public mutating func remember(_ key: String, now: Date) -> Bool {
        while let oldest = recency.oldest {
            if let call = seen[oldest.key], call.use == oldest.use {
                guard call.expiry <= now else { break }
                seen[oldest.key] = nil
            }
            _ = recency.popOldest()
        }
        if let call = seen[key], call.expiry > now { return false }
        let use = recency.append(key)
        seen[key] = Call(expiry: now.addingTimeInterval(lifetime), use: use)
        while seen.count > maxKeys, let oldest = recency.popOldest() {
            if seen[oldest.key]?.use == oldest.use { seen[oldest.key] = nil }
        }
        if recency.needsCompacting(keeping: maxKeys) {
            recency.keep(recency.entries.filter { seen[$0.key]?.use == $0.use })
        }
        return true
    }

    /// Forgets `key`, so a retry after a failure that rang nothing can ring.
    public mutating func forget(_ key: String) {
        seen[key] = nil
    }

    var count: Int { seen.count }
    var tracked: Int { recency.entries.count }
}

/// Keys in the order they were last used. Using a key again appends a new entry and leaves the old one
/// behind, superseded; callers tell live entries by the `use` number they stored with the key. Popping
/// may return superseded entries for the caller to skip, and the owner compacts the queue once it holds
/// more than twice its live keys, so each operation costs constant time on average.
struct RecencyQueue: Sendable {
    struct Entry: Sendable {
        var key: String
        var use: UInt64
    }

    private var storage: [Entry] = []
    private var head = 0
    private var uses: UInt64 = 0

    /// The entries still queued, oldest first.
    var entries: ArraySlice<Entry> { storage[head...] }

    var oldest: Entry? { head < storage.count ? storage[head] : nil }

    /// Appends `key` and returns its use number.
    mutating func append(_ key: String) -> UInt64 {
        uses += 1
        storage.append(Entry(key: key, use: uses))
        return uses
    }

    mutating func popOldest() -> Entry? {
        guard head < storage.count else { return nil }
        head += 1
        return storage[head - 1]
    }

    /// Whether the storage, including popped entries, has grown past twice `limit` live keys plus slack.
    func needsCompacting(keeping limit: Int) -> Bool {
        storage.count > 2 * limit + 16
    }

    /// Replaces the queue with `live`, the entries still in use, in order.
    mutating func keep(_ live: [Entry]) {
        storage = live
        head = 0
    }
}
