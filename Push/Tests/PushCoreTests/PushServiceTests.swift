import Crypto
import Foundation
@testable import PushCore
import PushWire
import XCTest

final class PushServiceTests: XCTestCase {
    // MARK: Register

    func testRegisteringSealsTheTokenToThePhonesKey() async throws {
        let f = Fixture()
        let body = try JSONEncoder().encode(PushRegistration.signed(token: f.token, environment: .sandbox,
                                                                    timestamp: f.seconds, by: f.phone))
        let response = await f.service.register(body, address: "192.0.2.1", now: f.now)
        XCTAssertEqual(response.status, 200)
        let sealed = try JSONDecoder().decode(PushRegistered.self, from: response.body).sealed
        let destination = try XCTUnwrap(TokenSealer(key: f.sealKey).open(sealed))
        XCTAssertEqual(destination.token, f.token)
        XCTAssertEqual(destination.environment, .sandbox)
        XCTAssertEqual(destination.deviceKeyHash, Data(SHA256.hash(data: f.phone.publicKey.x963Representation)))
        XCTAssertEqual(destination.issuedAt, f.seconds)
    }

    func testRegisteringRefusesForgedStaleMalformedAndTooFrequentRequests() async throws {
        var limits = PushLimits()
        limits.registrationsPerAddressPerMinute = 3
        let f = Fixture(limits: limits)
        var forged = try PushRegistration.signed(token: f.token, environment: .production, timestamp: f.seconds, by: f.phone)
        forged.deviceKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let stale = try PushRegistration.signed(token: f.token, environment: .production, timestamp: f.seconds - 61, by: f.phone)

        let forgedResponse = await f.service.register(try JSONEncoder().encode(forged), address: "a", now: f.now)
        let staleResponse = await f.service.register(try JSONEncoder().encode(stale), address: "a", now: f.now)
        let malformed = await f.service.register(Data("{}".utf8), address: "a", now: f.now)
        XCTAssertEqual([forgedResponse.status, staleResponse.status, malformed.status], [401, 401, 400])

        let fresh = try JSONEncoder().encode(PushRegistration.signed(token: f.token, environment: .production,
                                                                     timestamp: f.seconds, by: f.phone))
        let limited = await f.service.register(fresh, address: "a", now: f.now)
        let elsewhere = await f.service.register(fresh, address: "b", now: f.now)
        XCTAssertEqual(limited.status, 429, "The address used its three registrations")
        XCTAssertEqual(elsewhere.status, 200)
    }

    // MARK: Ring

    func testAValidRingSendsTheCallToTheSealedTokenAndHost() async throws {
        let f = Fixture()
        let callID = UUID()
        let response = await f.service.ring(try f.ring(f.grant(sealed: f.sealed(environment: .sandbox)), callID: callID),
                                            address: f.address, now: f.now)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try f.result(response), PushRingResult(outcome: .sent, apnsStatus: 200))
        let pushes = await f.sender.pushes
        let hubHash = Data(SHA256.hash(data: f.hub.publicKey.x963Representation))
        XCTAssertEqual(pushes, [VoIPPush(token: f.token, environment: .sandbox,
                                         payload: PushCallPayload(callID: callID, expiresAt: f.seconds + 45, hub: hubHash,
                                                                  blob: Data("encrypted caller".utf8)))],
                       "The payload names the ringing Hub, so the phone can end calls from Hubs it does not know")
    }

    func testGrantsAreCheckedForSignatureExpiryAndHub() async throws {
        let f = Fixture()
        let otherPhone = P256.Signing.PrivateKey()
        let otherHub = P256.Signing.PrivateKey()
        var tampered = try f.grant()
        tampered.expiresAt += 1

        let cases: [(String, Data, Int, PushRingResult.Outcome, String)] = [
            ("expired", try f.ring(f.grant(expiresIn: -1)), 403, .grantExpired, "grantExpired"),
            ("too long", try f.ring(f.grant(expiresIn: 40 * 86_400)), 403, .rejected, "grantTooLong"),
            ("over 15 days", try f.ring(f.grant(expiresIn: 15 * 86_400 + 1)), 403, .rejected, "grantTooLong"),
            ("wrong hub", try f.ring(f.grant(), signer: otherHub), 401, .rejected, "badSignature"),
            ("granted to another hub", try f.ring(f.grant(hub: otherHub)), 401, .rejected, "badSignature"),
            ("bad grant signature", try f.ring(tampered), 401, .rejected, "badGrant"),
            ("another phone's token", try f.ring(f.grant(by: otherPhone)), 401, .rejected, "badGrant"),
            ("unsealed token", try f.ring(f.grant(sealed: Data("forged".utf8))), 401, .rejected, "badSealedToken"),
            ("stale", try f.ring(skew: -61), 401, .rejected, "staleRequest"),
            ("from the future", try f.ring(skew: 61), 401, .rejected, "staleRequest"),
            ("rings too long", try f.ring(secondsLeft: 301), 400, .rejected, "malformed"),
            ("not a request", Data("[]".utf8), 400, .rejected, "malformed"),
        ]
        for (name, body, status, outcome, reason) in cases {
            let response = await f.service.ring(body, address: f.address, now: f.now)
            XCTAssertEqual(response.status, status, name)
            XCTAssertEqual(try f.result(response).outcome, outcome, name)
            XCTAssertEqual(try f.result(response).reason, reason, name)
        }
        let pushes = await f.sender.pushes
        XCTAssertTrue(pushes.isEmpty)
        let edge = await f.service.ring(try f.ring(skew: 60), address: f.address, now: f.now)
        XCTAssertEqual(edge.status, 200, "Up to a minute of clock difference is fine")
        let fifteenDays = await f.service.ring(try f.ring(f.grant(expiresIn: 15 * 86_400)), address: f.address, now: f.now)
        XCTAssertEqual(fifteenDays.status, 200, "A 15-day grant is the longest Push accepts")
    }

    func testARegistrationOlderThan90DaysAsksForANewOne() async throws {
        let f = Fixture()
        let old = await f.service.ring(try f.ring(f.grant(sealed: f.sealed(issuedAt: f.seconds - 90 * 86_400 - 1))),
                                       address: f.address, now: f.now)
        XCTAssertEqual(old.status, 403)
        XCTAssertEqual(try f.result(old), PushRingResult(outcome: .registrationExpired, reason: "registrationExpired"))
        let pushes = await f.sender.pushes
        XCTAssertTrue(pushes.isEmpty)

        let current = await f.service.ring(try f.ring(f.grant(sealed: f.sealed(issuedAt: f.seconds - 90 * 86_400))),
                                           address: f.address, now: f.now)
        XCTAssertEqual(current.status, 200, "A 90-day-old registration still rings")
    }

    func testRingsAreLimitedPerAddressBeforeAnyParsingOrCryptography() async throws {
        var limits = PushLimits()
        limits.ringsPerAddressPerMinute = 2
        let f = Fixture(limits: limits)
        // Garbage costs the sender its rings too: the address is limited before the body is even read.
        for _ in 0..<2 {
            let garbage = await f.service.ring(Data("not json".utf8), address: "2001:db8:1:2::1", now: f.now)
            XCTAssertEqual(garbage.status, 400)
        }
        let limited = await f.service.ring(try f.ring(), address: "2001:db8:1:2:ffff:ffff:ffff:9", now: f.now)
        XCTAssertEqual(limited.status, 429, "One IPv6 /64 is one address")
        XCTAssertEqual(try f.result(limited), PushRingResult(outcome: .rateLimited, reason: "addressLimit"))
        let forged = await f.service.ring(try f.ring(f.grant(sealed: Data("forged".utf8))), address: "2001:db8:1:2::1",
                                          now: f.now)
        XCTAssertEqual(try f.result(forged).reason, "addressLimit", "Limited before the sealed token is opened")
        let pushes = await f.sender.pushes
        XCTAssertTrue(pushes.isEmpty)

        let otherPrefix = await f.service.ring(try f.ring(), address: "2001:db8:1:3::1", now: f.now)
        XCTAssertEqual(otherPrefix.status, 200)
        let otherAddress = await f.service.ring(try f.ring(), address: "192.0.2.10", now: f.now)
        XCTAssertEqual(otherAddress.status, 200)
    }

    func testAddressesAreLimitedAsIPv4AddressesOrIPv6Prefixes() {
        XCTAssertEqual(PushService.clientAddress("192.0.2.1"), "192.0.2.1")
        XCTAssertEqual(PushService.clientAddress("2001:db8:a:b:c:d:e:f"), "2001:db8:a:b::/64")
        XCTAssertEqual(PushService.clientAddress("2001:DB8:A:B::1"), "2001:db8:a:b::/64")
        XCTAssertEqual(PushService.clientAddress("2001:db8::"), "2001:db8:0:0::/64")
        XCTAssertEqual(PushService.clientAddress("::1"), "0:0:0:0::/64")
        XCTAssertEqual(PushService.clientAddress("fe80::1%en0"), "fe80:0:0:0::/64")
        XCTAssertEqual(PushService.clientAddress("::ffff:192.0.2.1"), "192.0.2.1", "IPv4-mapped is IPv4")
        XCTAssertEqual(PushService.clientAddress("2001:db8:a:b:c:d:192.0.2.1"), "2001:db8:a:b::/64")
        XCTAssertEqual(PushService.clientAddress("unknown"), "unknown")
        XCTAssertEqual(PushService.clientAddress("2001:db8:::1"), "2001:db8:::1", "Not an address: kept as given")
        XCTAssertEqual(PushService.clientAddress(String(repeating: "x", count: 500)).count, 64, "and kept short")
    }

    func testRegistrationsAreLimitedPerIPv6Prefix() async throws {
        var limits = PushLimits()
        limits.registrationsPerAddressPerMinute = 1
        let f = Fixture(limits: limits)
        let body = try JSONEncoder().encode(PushRegistration.signed(token: f.token, environment: .production,
                                                                    timestamp: f.seconds, by: f.phone))
        let first = await f.service.register(body, address: "2001:db8:5:6::1", now: f.now)
        let samePrefix = await f.service.register(body, address: "2001:db8:5:6:a:b:c:d", now: f.now)
        let otherPrefix = await f.service.register(body, address: "2001:db8:5:7::1", now: f.now)
        XCTAssertEqual([first.status, samePrefix.status, otherPrefix.status], [200, 429, 200])
    }

    func testACallRingsEachDeviceOnceHoweverOftenItIsSent() async throws {
        let f = Fixture()
        let callID = UUID()
        let body = try f.ring(callID: callID)
        let first = await f.service.ring(body, address: f.address, now: f.now)
        let replayed = await f.service.ring(body, address: f.address, now: f.now.addingTimeInterval(5))
        let retried = await f.service.ring(try f.ring(callID: callID), address: f.address, now: f.now)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(try f.result(replayed).outcome, .duplicate)
        XCTAssertEqual(try f.result(retried).outcome, .duplicate)

        let iPad = P256.Signing.PrivateKey()
        let otherDevice = await f.service.ring(
            try f.ring(f.grant(sealed: f.sealed(token: Data([9, 9]), for: iPad), by: iPad), callID: callID), address: f.address, now: f.now)
        XCTAssertEqual(try f.result(otherDevice).outcome, .sent, "The same call rings each of the person's devices")
        let count = await f.sender.pushes.count
        XCTAssertEqual(count, 2)
    }

    func testRingsAreLimitedPerHubAndDevice() async throws {
        let f = Fixture()
        for _ in 0..<2 {
            let response = await f.service.ring(try f.ring(), address: f.address, now: f.now)
            XCTAssertEqual(response.status, 200)
        }
        let third = await f.service.ring(try f.ring(), address: f.address, now: f.now)
        XCTAssertEqual(third.status, 429)
        XCTAssertEqual(try f.result(third).reason, "hubDeviceLimit")

        // Other phones of the same Hub share its ten rings a minute; the refused ring did not count.
        for index in 0..<8 {
            let phone = P256.Signing.PrivateKey()
            let grant = try f.grant(sealed: f.sealed(token: Data([UInt8(index)]), for: phone), by: phone)
            let response = await f.service.ring(try f.ring(grant), address: f.address, now: f.now)
            XCTAssertEqual(response.status, 200)
        }
        let phone = P256.Signing.PrivateKey()
        let grant = try f.grant(sealed: f.sealed(token: Data([42]), for: phone), by: phone)
        let overHub = await f.service.ring(try f.ring(grant), address: f.address, now: f.now)
        XCTAssertEqual(overHub.status, 429)
        XCTAssertEqual(try f.result(overHub).reason, "hubLimit")
        let later = await f.service.ring(try f.ring(grant), address: f.address, now: f.now.addingTimeInterval(7))
        XCTAssertEqual(later.status, 200, "The Hub's bucket refills a ring every 6 s")
    }

    func testOneHubCannotUseUpAPhonesRingsForTheOthers() async throws {
        let f = Fixture()
        let otherHub = P256.Signing.PrivateKey()
        let thirdHub = P256.Signing.PrivateKey()
        for _ in 0..<2 {
            let response = await f.service.ring(try f.ring(), address: f.address, now: f.now)
            XCTAssertEqual(response.status, 200)
        }
        let buggyHub = await f.service.ring(try f.ring(), address: f.address, now: f.now)
        XCTAssertEqual(try f.result(buggyHub).reason, "hubDeviceLimit")
        let other = await f.service.ring(try f.ring(f.grant(hub: otherHub), signer: otherHub), address: f.address, now: f.now)
        XCTAssertEqual(other.status, 200, "Another Hub can still ring the phone")
        let third = await f.service.ring(try f.ring(f.grant(hub: thirdHub), signer: thirdHub), address: f.address, now: f.now)
        XCTAssertEqual(third.status, 429)
        XCTAssertEqual(try f.result(third).reason, "deviceLimit", "The phone's own three a minute still hold")
    }

    func testTheDeviceLimitFollowsTheTokenHoweverManyKeysRegisteredIt() async throws {
        var limits = PushLimits()
        limits.ringsPerHubPerDevicePerMinute = 100
        let f = Fixture(limits: limits)
        // A leaked token, registered under one fresh key per ring.
        for _ in 0..<3 {
            let key = P256.Signing.PrivateKey()
            let response = await f.service.ring(try f.ring(f.grant(sealed: f.sealed(for: key), by: key)), address: f.address,
                                                now: f.now)
            XCTAssertEqual(response.status, 200)
        }
        let key = P256.Signing.PrivateKey()
        let fourth = await f.service.ring(try f.ring(f.grant(sealed: f.sealed(for: key), by: key)), address: f.address,
                                          now: f.now)
        XCTAssertEqual(fourth.status, 429)
        XCTAssertEqual(try f.result(fourth).reason, "deviceLimit")

        let sandbox = await f.service.ring(try f.ring(f.grant(sealed: f.sealed(environment: .sandbox, for: key), by: key)),
                                           address: f.address, now: f.now)
        XCTAssertEqual(sandbox.status, 200, "The same bytes on the other APNs host are another device")
    }

    func testACallRingsATokenOnceHoweverManyKeysRegisteredIt() async throws {
        let f = Fixture()
        let callID = UUID()
        let first = await f.service.ring(try f.ring(callID: callID), address: f.address, now: f.now)
        let key = P256.Signing.PrivateKey()
        let again = await f.service.ring(try f.ring(f.grant(sealed: f.sealed(for: key), by: key), callID: callID),
                                         address: f.address, now: f.now)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(try f.result(again).outcome, .duplicate)
    }

    func testAGoneTokenTellsTheHubToDropTheGrant() async throws {
        var limits = PushLimits()
        limits.ringsPerDevicePerMinute = 100
        limits.ringsPerHubPerDevicePerMinute = 100
        let f = Fixture(limits: limits)
        for (status, reason) in [(410, "Unregistered"), (410, "ExpiredToken"), (400, "BadDeviceToken"), (400, "DeviceTokenNotForTopic")] {
            await f.sender.answer(.refused(status: status, reason: reason))
            let response = await f.service.ring(try f.ring(), address: f.address, now: f.now)
            XCTAssertEqual(response.status, 410, reason)
            XCTAssertEqual(try f.result(response), PushRingResult(outcome: .unregistered, apnsStatus: status, reason: reason))
        }
    }

    func testAFailedSendCanBeRetriedWithoutCountingAsARing() async throws {
        let f = Fixture()
        let callID = UUID()
        await f.sender.answer(.unreachable)
        let unreachable = await f.service.ring(try f.ring(callID: callID), address: f.address, now: f.now)
        XCTAssertEqual(unreachable.status, 503)
        await f.sender.answer(.refused(status: 503, reason: "ServiceUnavailable"))
        let unavailable = await f.service.ring(try f.ring(callID: callID), address: f.address, now: f.now)
        XCTAssertEqual(unavailable.status, 503)
        XCTAssertEqual(try f.result(unavailable), PushRingResult(outcome: .failed, apnsStatus: 503, reason: "ServiceUnavailable"))
        await f.sender.answer(.refused(status: 403, reason: "InvalidProviderToken"))
        let misconfigured = await f.service.ring(try f.ring(callID: callID), address: f.address, now: f.now)
        XCTAssertEqual(misconfigured.status, 502)

        await f.sender.answer(.sent)
        let retried = await f.service.ring(try f.ring(callID: callID), address: f.address, now: f.now)
        XCTAssertEqual(try f.result(retried).outcome, .sent, "Nothing rang before, so the retry rings")
    }

    func testLogsNeverCarryTokensGrantsOrPayloads() async throws {
        let f = Fixture()
        let grant = try f.grant()
        let registration = try PushRegistration.signed(token: f.token, environment: .production, timestamp: f.seconds, by: f.phone)
        let registered = await f.service.register(try JSONEncoder().encode(registration), address: "192.0.2.7", now: f.now)
        let ring = try JSONDecoder().decode(PushRingRequest.self, from: f.ring(grant))
        _ = await f.service.ring(try JSONEncoder().encode(ring), address: f.address, now: f.now)
        await f.sender.answer(.refused(status: 410, reason: "Unregistered"))
        _ = await f.service.ring(try f.ring(grant), address: f.address, now: f.now)
        _ = await f.service.ring(try f.ring(grant, skew: 500), address: f.address, now: f.now)

        let logs = f.logs.lines.joined(separator: "\n")
        XCTAssertFalse(f.logs.lines.isEmpty)
        let secrets: [Data] = [f.token, grant.sealed, grant.signature, grant.deviceKey, grant.hubKey, ring.signature, ring.blob,
                               registration.signature, try JSONDecoder().decode(PushRegistered.self, from: registered.body).sealed]
        for secret in secrets {
            XCTAssertFalse(logs.contains(secret.base64EncodedString()), "A secret reached the logs")
            XCTAssertFalse(logs.contains(secret.map { String(format: "%02x", $0) }.joined()), "A secret reached the logs")
        }
        XCTAssertFalse(logs.contains("encrypted caller"))
        XCTAssertFalse(logs.contains("192.0.2.7"))
        XCTAssertFalse(logs.contains(f.address))
        XCTAssertTrue(logs.contains("hub=\(PushService.shortHash(grant.hubKey))"), logs)
    }
}
