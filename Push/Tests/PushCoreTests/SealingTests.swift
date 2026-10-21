import Crypto
import Foundation
@testable import PushCore
import PushWire
import XCTest

final class SealingTests: XCTestCase {
    private let destination = SealedDestination(token: Data([1, 2, 3, 4]), environment: .sandbox,
                                                deviceKeyHash: Data(repeating: 7, count: 32), issuedAt: 1_800_000_000)

    func testASealedTokenOpensOnlyWithItsKeyAndUnchanged() throws {
        let sealer = try TokenSealer(key: SymmetricKey(size: .bits256))
        let sealed = try sealer.seal(destination)
        XCTAssertEqual(sealer.open(sealed), destination)
        XCTAssertEqual(sealed.first, 1, "The format byte leads")
        XCTAssertNil(sealed.range(of: destination.token), "The token is not readable inside")

        XCTAssertNil(try TokenSealer(key: SymmetricKey(size: .bits256)).open(sealed), "Another key cannot open it")
        var changed = sealed
        changed[changed.count - 20] ^= 1
        XCTAssertNil(sealer.open(changed))
        var reformatted = sealed
        reformatted[0] = 2
        XCTAssertNil(sealer.open(reformatted))
        XCTAssertNil(sealer.open(Data()))
        XCTAssertNotEqual(try sealer.seal(destination), sealed, "Each seal uses a new nonce")
    }

    func testTheSealKeyMustBe256Bits() {
        XCTAssertThrowsError(try TokenSealer(key: SymmetricKey(size: .bits128)))
    }

    func testConfigurationNamesWhatIsMissingButNeverAValue() throws {
        let p8 = P256.Signing.PrivateKey().pemRepresentation
        let seal = Data(repeating: 9, count: 32).base64EncodedString()
        let complete = ["PUSH_SEAL_KEY": seal, "APNS_KEY_P8": p8, "APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "S8VNVK39LH"]

        let configuration = try PushConfiguration(environment: complete)
        XCTAssertEqual(configuration.topic, "com.pdparchitect.noodle.mobile.voip")
        XCTAssertEqual(configuration.port, 8080)
        XCTAssertEqual(configuration.teamID, "S8VNVK39LH")

        // Secret stores may keep the PEM's line breaks escaped, or the whole file as base64.
        let escaped = p8.replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertNoThrow(try PushConfiguration(environment: complete.merging(["APNS_KEY_P8": escaped]) { $1 }))
        let encoded = Data(p8.utf8).base64EncodedString()
        XCTAssertNoThrow(try PushConfiguration(environment: complete.merging(["APNS_KEY_P8": encoded]) { $1 }))

        for name in complete.keys {
            var missing = complete
            missing[name] = nil
            XCTAssertThrowsError(try PushConfiguration(environment: missing)) { error in
                XCTAssertTrue("\(error)".contains(name), "\(error)")
            }
        }
        XCTAssertThrowsError(try PushConfiguration(environment: complete.merging(["PUSH_SEAL_KEY": "c2hvcnQ="]) { $1 })) { error in
            XCTAssertFalse("\(error)".contains("c2hvcnQ="))
        }
        XCTAssertThrowsError(try PushConfiguration(environment: complete.merging(["APNS_KEY_P8": "not a key"]) { $1 })) { error in
            XCTAssertFalse("\(error)".contains("not a key"))
        }
    }

    func testBucketsAllowABurstThenRefillOverTime() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var limiter = RateLimiter(perMinute: 3)
        XCTAssertEqual((0..<4).map { _ in limiter.allow("hub", now: start) }, [true, true, true, false])
        XCTAssertTrue(limiter.allow("other", now: start), "Each key has its own bucket")
        XCTAssertFalse(limiter.allow("hub", now: start.addingTimeInterval(10)))
        XCTAssertTrue(limiter.allow("hub", now: start.addingTimeInterval(20)), "One token every 20 s")
        XCTAssertFalse(limiter.allow("hub", now: start.addingTimeInterval(21)))
        limiter.refund("hub")
        XCTAssertTrue(limiter.allow("hub", now: start.addingTimeInterval(21)))
    }

    func testALimiterForgetsTheLeastRecentlyUsedKeyWhenFull() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var limiter = RateLimiter(perMinute: 1, maxKeys: 2)
        XCTAssertTrue(limiter.allow("a", now: start))
        XCTAssertTrue(limiter.allow("b", now: start))
        XCTAssertFalse(limiter.allow("a", now: start), "a is empty, and now used more recently than b")
        XCTAssertTrue(limiter.allow("c", now: start))
        XCTAssertEqual(limiter.count, 2)
        XCTAssertFalse(limiter.allow("a", now: start), "a was kept")
        XCTAssertTrue(limiter.allow("b", now: start), "b was forgotten, so it starts full again")
    }

    func testALimiterStaysBoundedUnderAFloodOfKeys() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var limiter = RateLimiter(perMinute: 3, maxKeys: 100)
        for index in 0..<10_000 {
            _ = limiter.allow("flood-\(index)", now: start)
            _ = limiter.allow("steady", now: start)
        }
        XCTAssertEqual(limiter.count, 100)
        XCTAssertLessThanOrEqual(limiter.tracked, 2 * 100 + 16, "The recency queue is compacted, not left to grow")
        XCTAssertFalse(limiter.allow("steady", now: start), "A key in use is never the one forgotten")
    }

    func testCallMemoryStaysBoundedAndForgetsExpiredCallsFirst() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var memory = CallMemory(lifetime: 300, maxKeys: 100)
        for index in 0..<10_000 {
            _ = memory.remember("call-\(index)", now: start.addingTimeInterval(Double(index) / 100))
        }
        XCTAssertEqual(memory.count, 100)
        XCTAssertLessThanOrEqual(memory.tracked, 2 * 100 + 16)
        XCTAssertFalse(memory.remember("call-9999", now: start.addingTimeInterval(100)), "Recent calls are kept")
        _ = memory.remember("late", now: start.addingTimeInterval(1_000))
        XCTAssertEqual(memory.count, 1, "Expired calls go as time passes")
    }

    func testCallMemoryRemembersUntilItsLifetimeEnds() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var memory = CallMemory(lifetime: 300)
        XCTAssertTrue(memory.remember("call", now: start))
        XCTAssertFalse(memory.remember("call", now: start.addingTimeInterval(299)))
        XCTAssertTrue(memory.remember("call", now: start.addingTimeInterval(301)))
        memory.forget("call")
        XCTAssertTrue(memory.remember("call", now: start.addingTimeInterval(302)))
    }
}
