import Foundation

/// Token buckets per key, in memory. Push runs as one instance (`max_instances = 1`), so this holds for
/// v1; a restart or a second instance forgets them, which only lets a few extra rings through.
public struct RateLimiter: Sendable {
    private struct Bucket: Sendable {
        var tokens: Double
        var updated: Date
    }

    /// The most requests in a burst; the bucket refills to this.
    public let capacity: Double
    /// Requests regained per second.
    public let refill: Double
    private var buckets: [String: Bucket] = [:]

    public init(perMinute: Double, burst: Double? = nil) {
        capacity = burst ?? perMinute
        refill = perMinute / 60
    }

    /// Whether `key` may make a request now; takes one if so.
    public mutating func allow(_ key: String, now: Date) -> Bool {
        var bucket = buckets[key].map { refilled($0, now: now) } ?? Bucket(tokens: capacity, updated: now)
        guard bucket.tokens >= 1 else {
            buckets[key] = bucket
            return false
        }
        bucket.tokens -= 1
        buckets[key] = bucket
        if buckets.count > 10_000 { forgetFull(now: now) }
        return true
    }

    /// Puts back a token taken for a request that never reached APNs.
    public mutating func refund(_ key: String) {
        guard var bucket = buckets[key] else { return }
        bucket.tokens = min(capacity, bucket.tokens + 1)
        buckets[key] = bucket
    }

    var count: Int { buckets.count }

    private func refilled(_ bucket: Bucket, now: Date) -> Bucket {
        let elapsed = max(0, now.timeIntervalSince(bucket.updated))
        return Bucket(tokens: min(capacity, bucket.tokens + elapsed * refill), updated: now)
    }

    /// A full bucket is the same as none.
    private mutating func forgetFull(now: Date) {
        buckets = buckets.filter { refilled($0.value, now: now).tokens < capacity }
    }
}

/// Call IDs Push already rang each device for, so a replayed or retried request rings once.
public struct CallMemory: Sendable {
    private var seen: [String: Date] = [:]
    public let lifetime: TimeInterval

    public init(lifetime: TimeInterval) { self.lifetime = lifetime }

    /// Remembers `key`; false when it was already remembered and has not expired.
    public mutating func remember(_ key: String, now: Date) -> Bool {
        if let expiry = seen[key], expiry > now { return false }
        if seen.count > 10_000 { seen = seen.filter { $0.value > now } }
        seen[key] = now.addingTimeInterval(lifetime)
        return true
    }

    /// Forgets `key`, so a retry after a failure that rang nothing can ring.
    public mutating func forget(_ key: String) {
        seen[key] = nil
    }
}
