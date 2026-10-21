import CryptoKit
import Foundation
@testable import HubLink
import XCTest

/// What a phone gives a Hub to ring it through Noodle Push, held to the bytes and vectors Push itself is
/// tested with (Push/Tests/PushWireTests), so the live service accepts what HubLink signs.
@MainActor final class LinkCallPushTests: XCTestCase {
    // PushWire's vector keys: the phone's scalar is 0x11 × 32, the Hub's 0x22 × 32.
    private let phone = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
    private let hub = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
    private static let vectorHubKey = "04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf3"
        + "50185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285"
    private static let vectorGrantSignature = "RdnIsnTTRBZu1LmdeE0bXQBxZtvonpSXAwmU+5eWkbJHAfnK5RR1cuW/fb2kMxNmpkmrb28kqsxJtMP4uP1dmg=="
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A device paired with the vector Hub using the vector phone key, as HubPairing keeps them.
    private func pairing() throws -> HubPairing {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-call-push-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try phone.rawRepresentation.write(to: folder.appendingPathComponent("device.key"))
        let saved = HubPairing.Hub(name: "Hub", key: LinkPublicKey(hub.publicKey), endpoints: [], userName: "Ada")
        try JSONEncoder().encode(saved).write(to: folder.appendingPathComponent("hub.json"))
        return HubPairing(directory: folder, deviceName: "iPhone")
    }

    func testAGrantFromAPairingIsTheGrantPushsVectorsPin() throws {
        let grant = try pairing().callGrant(sealed: Data([0x01, 0x02, 0x03]), expiresAt: Date(timeIntervalSince1970: 1_801_209_600))
        XCTAssertEqual(hex(grant.hubKey), Self.vectorHubKey)
        XCTAssertEqual(grant.deviceKey, phone.publicKey.x963Representation)
        XCTAssertEqual(grant.expiresAt, 1_801_209_600)
        XCTAssertTrue(grant.hasValidSignature)
        // The signature Push's own vector test verifies holds for these bytes too: they are the same.
        var vector = grant
        vector.signature = try XCTUnwrap(Data(base64Encoded: Self.vectorGrantSignature))
        XCTAssertTrue(vector.hasValidSignature)
        XCTAssertEqual(hex(grant.signedBytes), hex(Data("noodle-push-grant-v1".utf8)) + "00" + "00000003010203"
                       + "00000041" + hex(phone.publicKey.x963Representation) + "00000041" + Self.vectorHubKey
                       + "00000008000000006b5c4700")
    }

    func testARegistrationIsSignedWithTheKeyPairedWithThatHub() throws {
        let registration = try pairing().pushRegistration(token: Data([0xAB, 0xCD]), environment: .sandbox, now: now)
        XCTAssertEqual(registration.deviceKey, phone.publicKey.x963Representation)
        XCTAssertEqual(registration.timestamp, 1_800_000_000)
        XCTAssertTrue(registration.hasValidSignature)
        XCTAssertEqual(hex(registration.signedBytes), hex(Data("noodle-push-register-v1".utf8)) + "00" + "00000002abcd"
                       + "00000007" + hex(Data("sandbox".utf8)) + "00000041" + hex(phone.publicKey.x963Representation)
                       + "00000008000000006b49d200")
    }

    func testTheRequestAndTheStatusTravelAndOlderHubsReadAsNotRinging() throws {
        let grant = try CallGrant.signed(sealed: Data([1]), hubKey: hub.publicKey.x963Representation, expiresAt: 1_801_000_000, by: phone)
        let push = LinkCallPush(grant: grant, callKey: Data(repeating: 7, count: 32))
        guard case .success(.callPush(let decoded)) = LinkProtocol.decode(try LinkProtocol.encode(.callPush(push))) else {
            return XCTFail("The grant did not survive the link")
        }
        XCTAssertEqual(decoded, push)
        // As this release sends it, which later ones must keep reading.
        let stop = #"{"version":1,"request":{"callPush":{"_0":{}}}}"#
        XCTAssertEqual(try LinkProtocol.decode(Data(stop.utf8)).get(), .callPush(LinkCallPush(grant: nil, callKey: nil)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: LinkProtocol.encoder.encode(push)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["grant", "callKey"])
        XCTAssertEqual(Set((json["grant"] as? [String: Any] ?? [:]).keys), ["sealed", "deviceKey", "hubKey", "exp", "sig"])

        let old = try LinkProtocol.decoder.decode(LinkStatus.self, from: Data(#"{"hubName":"Hub"}"#.utf8))
        XCTAssertFalse(old.ringsThroughPush)
        XCTAssertNil(old.callPushExpiresAt)
        let status = LinkStatus(hubName: "Hub", userName: "Ada", planName: "", harnesses: [], endpoints: [], ringsThroughPush: true,
                                callPushExpiresAt: Date(timeIntervalSince1970: 1_801_000_000))
        XCTAssertEqual(try LinkProtocol.decodeResponse(LinkProtocol.encode(.status(status))), .status(status))
        let sent = #"{"status":{"_0":{"hubName":"Hub","ringsThroughPush":true,"callPushExpiresAt":1801000000}}}"#
        guard case .status(let read) = try LinkProtocol.decodeResponse(Data(sent.utf8)) else { return XCTFail("no status") }
        XCTAssertTrue(read.ringsThroughPush)
        XCTAssertEqual(read.callPushExpiresAt, Date(timeIntervalSince1970: 1_801_000_000))
    }

    /// The Hub keeps only a grant the device it came from signed for this Hub, current and within Push's 15 days.
    func testAHubKeepsOnlyACurrentGrantSignedForItByThatDevice() throws {
        let device = LinkPublicKey(phone.publicKey), hubKey = LinkPublicKey(hub.publicKey)
        let key = Data(repeating: 7, count: 32), seconds = Int64(now.timeIntervalSince1970)
        func push(_ expires: Int64 = 14 * 86_400, hub: Data? = nil, by signer: P256.Signing.PrivateKey? = nil,
                  key: Data = key) throws -> LinkCallPush {
            LinkCallPush(grant: try CallGrant.signed(sealed: Data([1, 2]), hubKey: hub ?? hubKey.x963, expiresAt: seconds + expires,
                                                     by: signer ?? phone), callKey: key)
        }
        let kept = try XCTUnwrap(try push().checked(device: device, hub: hubKey, now: now))
        XCTAssertEqual(kept.callKey, key)
        XCTAssertNil(try LinkCallPush(grant: nil, callKey: nil).checked(device: device, hub: hubKey, now: now), "Stopping")

        let other = P256.Signing.PrivateKey()
        let refused: [(String, LinkCallPush)] = [
            ("for another Hub", try push(hub: other.publicKey.x963Representation)),
            ("signed by another device", try push(by: other)),
            ("expired", try push(-1)),
            ("longer than Push accepts", try push(15 * 86_400 + 1)),
            ("with a short key", try push(key: Data(repeating: 7, count: 16))),
            ("without a key", LinkCallPush(grant: try push().grant, callKey: nil)),
        ]
        for (what, push) in refused {
            XCTAssertThrowsError(try push.checked(device: device, hub: hubKey, now: now), what)
        }
        var tampered = try push()
        tampered.grant?.sealed = Data([9])
        XCTAssertThrowsError(try tampered.checked(device: device, hub: hubKey, now: now), "changed after signing")
    }

    /// Only the phone, with its key for that Hub, reads who is calling, and only for the call it was sealed for.
    func testTheCallerOpensOnlyWithItsKeyForItsCall() throws {
        let key = Data(repeating: 3, count: 32), call = UUID()
        let caller = LinkCallPushCaller(botID: UUID(), botName: "Kai", conversationID: UUID())
        let blob = try caller.sealed(callID: call, with: key)
        XCTAssertEqual(LinkCallPushCaller.open(blob, callID: call, with: key), caller)
        XCTAssertNil(LinkCallPushCaller.open(blob, callID: UUID(), with: key), "Another call")
        XCTAssertNil(LinkCallPushCaller.open(blob, callID: call, with: Data(repeating: 4, count: 32)), "Another key")
        XCTAssertNil(LinkCallPushCaller.open(Data([1, 2, 3]), callID: call, with: key))
        XCTAssertFalse(String(decoding: blob, as: UTF8.self).contains("Kai"))

        let long = LinkCallPushCaller(botID: UUID(), botName: String(repeating: "🦊", count: 500), conversationID: UUID())
        XCTAssertEqual(long.botName.count, LinkCallPushCaller.longestName)
        XCTAssertLessThan(try long.sealed(callID: call, with: key).count, 2_048, "Push takes blobs up to 2 KB")
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
