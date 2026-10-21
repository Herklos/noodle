import Crypto
import Foundation
import PushWire
import XCTest

final class PushWireTests: XCTestCase {
    private let phone = P256.Signing.PrivateKey()
    private let hub = P256.Signing.PrivateKey()
    private let token = Data((0..<32).map { UInt8($0) })

    func testARegistrationProvesThePhoneHoldsItsKey() throws {
        let registration = try PushRegistration.signed(token: token, environment: .sandbox, timestamp: 1_800_000_000, by: phone)
        XCTAssertTrue(registration.hasValidSignature)
        XCTAssertEqual(registration.deviceKey, phone.publicKey.x963Representation)

        var changed = registration
        changed.environment = .production
        XCTAssertFalse(changed.hasValidSignature, "The environment is signed")
        changed = registration
        changed.deviceKey = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertFalse(changed.hasValidSignature, "Nobody registers a key they do not hold")
        changed = registration
        changed.signature = Data(repeating: 0, count: 64)
        XCTAssertFalse(changed.hasValidSignature)
    }

    func testAGrantNamesOneHubAndARingNeedsThatHubsSignature() throws {
        let grant = try CallGrant.signed(sealed: Data("sealed".utf8), hubKey: hub.publicKey.x963Representation,
                                         expiresAt: 1_801_000_000, by: phone)
        XCTAssertTrue(grant.hasValidSignature)
        var stretched = grant
        stretched.expiresAt += 86_400
        XCTAssertFalse(stretched.hasValidSignature, "A Hub cannot extend its grant")
        var moved = grant
        moved.hubKey = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertFalse(moved.hasValidSignature, "A Hub cannot hand its grant to another key")

        let ring = try PushRingRequest.signed(grant: grant, callID: UUID(), secondsLeft: 30, timestamp: 1_800_000_000,
                                              blob: Data("caller".utf8), by: hub)
        XCTAssertTrue(ring.hasValidSignature)
        let stranger = try PushRingRequest.signed(grant: grant, callID: UUID(), secondsLeft: 30, timestamp: 1_800_000_000,
                                                  blob: Data("caller".utf8), by: P256.Signing.PrivateKey())
        XCTAssertFalse(stranger.hasValidSignature, "Only the Hub the grant names can ring with it")

        var swapped = ring
        swapped.blob = Data("someone else".utf8)
        XCTAssertFalse(swapped.hasValidSignature)
        swapped = ring
        swapped.grant = try CallGrant.signed(sealed: Data("other phone".utf8), hubKey: hub.publicKey.x963Representation,
                                             expiresAt: 1_801_000_000, by: phone)
        XCTAssertFalse(swapped.hasValidSignature, "The grant is part of what the Hub signs")
    }

    func testTheJSONUsesTheDesignedNames() throws {
        let registration = try PushRegistration.signed(token: token, environment: .production, timestamp: 1, by: phone)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["token", "env", "deviceKey", "ts", "sig"])
        XCTAssertEqual(json["env"] as? String, "production")

        let grant = try CallGrant.signed(sealed: Data([1]), hubKey: hub.publicKey.x963Representation, expiresAt: 2, by: phone)
        let ring = try PushRingRequest.signed(grant: grant, callID: UUID(), secondsLeft: 30, timestamp: 1, blob: Data([2]), by: hub)
        let ringJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ring)) as? [String: Any])
        XCTAssertEqual(Set(ringJSON.keys), ["grant", "callID", "secondsLeft", "ts", "blob", "sig"])
        XCTAssertEqual(Set((ringJSON["grant"] as? [String: Any] ?? [:]).keys), ["sealed", "deviceKey", "hubKey", "exp", "sig"])
        XCTAssertEqual(try JSONDecoder().decode(PushRingRequest.self, from: JSONEncoder().encode(ring)), ring)

        let payload = PushCallPayload(callID: UUID(), expiresAt: 5, hub: Data([4]), blob: Data([3]))
        let payloadJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(Set(payloadJSON.keys), ["callID", "exp", "hub", "blob"])
    }

    // Vectors for the Mobile and Hub implementations: these bytes and signatures must not change.

    private let vectorPhone = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
    private let vectorHub = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
    private let vectorCall = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func vectorGrant() -> CallGrant {
        CallGrant(sealed: Data([0x01, 0x02, 0x03]), deviceKey: vectorPhone.publicKey.x963Representation,
                  hubKey: vectorHub.publicKey.x963Representation, expiresAt: 1_801_209_600, signature: Data())
    }

    func testSignedBytesMatchTheVectors() {
        let registration = PushRegistration(token: Data([0xAB, 0xCD]), environment: .sandbox,
                                            deviceKey: Data([0x04, 0x05]), timestamp: 1_800_000_000, signature: Data())
        XCTAssertEqual(hex(registration.signedBytes),
                       hex(Data("noodle-push-register-v1".utf8)) + "00" + "00000002abcd" + "00000007" + hex(Data("sandbox".utf8))
                           + "000000020405" + "00000008000000006b49d200")

        let grant = CallGrant(sealed: Data([0x01]), deviceKey: Data([0x02]), hubKey: Data([0x03]), expiresAt: 1, signature: Data([0x09]))
        let grantBytes = hex(Data("noodle-push-grant-v1".utf8)) + "00" + "0000000101" + "0000000102" + "0000000103"
            + "000000080000000000000001"
        XCTAssertEqual(hex(grant.signedBytes), grantBytes)

        let ring = PushRingRequest(grant: grant, callID: vectorCall, secondsLeft: 30, timestamp: 2, blob: Data([0xEE]), signature: Data())
        XCTAssertEqual(hex(ring.signedBytes),
                       hex(Data("noodle-push-ring-v1".utf8)) + "00" + String(format: "%08x", grantBytes.count / 2) + grantBytes
                           + "0000000109" + "00000010" + "6f9619ff8b86d011b42d00c04fc964ff"
                           + "00000008000000000000001e" + "000000080000000000000002" + "00000001ee")
    }

    func testVectorSignaturesVerify() throws {
        var grant = vectorGrant()
        grant.signature = try XCTUnwrap(Data(base64Encoded: Self.vectorGrantSignature))
        XCTAssertTrue(grant.hasValidSignature)
        let ring = PushRingRequest(grant: grant, callID: vectorCall, secondsLeft: 30, timestamp: 1_800_000_000,
                                   blob: Data([0xEE]), signature: try XCTUnwrap(Data(base64Encoded: Self.vectorRingSignature)))
        XCTAssertTrue(ring.hasValidSignature)
    }

    // The vector Hub's key and its hash were derived with openssl from the scalar 0x22 × 32, not CryptoKit.
    private static let vectorHubKey = "04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf3"
        + "50185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285"
    private static let vectorHubHash = "6fc66a90486171ca69b512be185d66a763a68ff2d34cda639e78cff9e98caeab"
    private static let vectorPayload = #"{"blob":"7g==","callID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","exp":1800000045,"#
        + #""hub":"b8ZqkEhhccpptRK+GF1mp2Omj/LTTNpjnnjP+emMrqs="}"#

    func testThePayloadVectorNamesTheHubByItsKeysHash() throws {
        XCTAssertEqual(hex(vectorHub.publicKey.x963Representation), Self.vectorHubKey)
        let hubHash = PushCallPayload.hubHash(for: vectorHub.publicKey.x963Representation)
        XCTAssertEqual(hex(hubHash), Self.vectorHubHash)

        let payload = PushCallPayload(callID: vectorCall, expiresAt: 1_800_000_045, hub: hubHash, blob: Data([0xEE]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(decoding: try encoder.encode(payload), as: UTF8.self), Self.vectorPayload)
        XCTAssertEqual(try JSONDecoder().decode(PushCallPayload.self, from: Data(Self.vectorPayload.utf8)), payload)
    }

    private static let vectorGrantSignature = "RdnIsnTTRBZu1LmdeE0bXQBxZtvonpSXAwmU+5eWkbJHAfnK5RR1cuW/fb2kMxNmpkmrb28kqsxJtMP4uP1dmg=="
    private static let vectorRingSignature = "O9PrB13i5+T+PJNOQu291Vjl/HJ02oFm8cHw4H1LfDpe0Rc9vdOfCR9WQLuU7bLbrL9Uyqh9EEKHyi+yrg+Brw=="

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
