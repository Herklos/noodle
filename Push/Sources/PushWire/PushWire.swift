import Crypto
import Foundation

// The messages between the phone, the Hub and Noodle Push.
//
// Keys are the P-256 signing keys HubLink already pairs with (`LinkIdentity`), carried as their x9.63
// bytes like `LinkPublicKey.x963`. Signatures are ECDSA over SHA-256 in raw r‖s form, as `joinProof`
// uses, and each covers a domain-tagged, length-prefixed byte string (`PushSigning`) instead of JSON, so
// that no side depends on how another encodes it. Byte fields travel as base64 in JSON.
//
// 1. The phone posts a `PushRegistration` to `/v1/register` and gets back `PushRegistered.sealed`: its
//    VoIP token, sealed with a key only Push holds.
// 2. The phone gives each paired Hub a `CallGrant` over HubLink: the sealed token, the Hub's key and an
//    expiry, signed by the phone.
// 3. To ring, the Hub posts a `PushRingRequest` to `/v1/ring` carrying that grant, signed by the Hub,
//    and gets back a `PushRingResult`. The phone receives a `PushCallPayload` in the VoIP push, which
//    names the ringing Hub by its key's hash.

/// Which APNs host a token belongs to. The phone's build decides: debug builds get sandbox tokens.
public enum PushAPNsEnvironment: String, Codable, Sendable, CaseIterable {
    case sandbox
    case production
}

/// `POST /v1/register`, sent by the phone whenever PushKit gives it a token.
public struct PushRegistration: Codable, Sendable, Equatable {
    /// The VoIP token's raw bytes, as PushKit gives them.
    public var token: Data
    public var environment: PushAPNsEnvironment
    /// The phone's `LinkIdentity` public key (x9.63).
    public var deviceKey: Data
    /// Seconds since 1970 when the phone signed this.
    public var timestamp: Int64
    public var signature: Data

    enum CodingKeys: String, CodingKey {
        case token, environment = "env", deviceKey, timestamp = "ts", signature = "sig"
    }

    public init(token: Data, environment: PushAPNsEnvironment, deviceKey: Data, timestamp: Int64, signature: Data) {
        self.token = token
        self.environment = environment
        self.deviceKey = deviceKey
        self.timestamp = timestamp
        self.signature = signature
    }

    /// A registration signed by the phone's key.
    public static func signed(token: Data, environment: PushAPNsEnvironment, timestamp: Int64,
                              by key: P256.Signing.PrivateKey) throws -> PushRegistration {
        var registration = PushRegistration(token: token, environment: environment,
                                            deviceKey: key.publicKey.x963Representation, timestamp: timestamp, signature: Data())
        registration.signature = try key.signature(for: registration.signedBytes).rawRepresentation
        return registration
    }

    /// What `signature` covers.
    public var signedBytes: Data {
        PushSigning.message("noodle-push-register-v1",
                            [token, Data(environment.rawValue.utf8), deviceKey, PushSigning.bytes(timestamp)])
    }

    /// Whether `deviceKey` signed this, which proves the sender holds the key the token gets bound to.
    public var hasValidSignature: Bool {
        PushSigning.isValid(signature, by: deviceKey, for: signedBytes)
    }
}

/// The answer to a registration: the token sealed for Push alone, to hand to the Hubs inside grants.
public struct PushRegistered: Codable, Sendable, Equatable {
    public var sealed: Data
    public init(sealed: Data) { self.sealed = sealed }
}

/// The phone's permission for one Hub to ring it through Push until `expiresAt`. The phone sends it to
/// the Hub over HubLink and renews it on every connect and whenever its token changes.
public struct CallGrant: Codable, Sendable, Equatable {
    /// `PushRegistered.sealed`.
    public var sealed: Data
    /// The phone's key, which signed this grant. Push checks it is the key the token was sealed for.
    public var deviceKey: Data
    /// The Hub's `LinkIdentity` public key: only this key can ring with the grant.
    public var hubKey: Data
    /// Seconds since 1970.
    public var expiresAt: Int64
    public var signature: Data

    enum CodingKeys: String, CodingKey {
        case sealed, deviceKey, hubKey, expiresAt = "exp", signature = "sig"
    }

    public init(sealed: Data, deviceKey: Data, hubKey: Data, expiresAt: Int64, signature: Data) {
        self.sealed = sealed
        self.deviceKey = deviceKey
        self.hubKey = hubKey
        self.expiresAt = expiresAt
        self.signature = signature
    }

    /// A grant for the Hub with `hubKey`, signed by the phone's key.
    public static func signed(sealed: Data, hubKey: Data, expiresAt: Int64,
                              by key: P256.Signing.PrivateKey) throws -> CallGrant {
        var grant = CallGrant(sealed: sealed, deviceKey: key.publicKey.x963Representation, hubKey: hubKey,
                              expiresAt: expiresAt, signature: Data())
        grant.signature = try key.signature(for: grant.signedBytes).rawRepresentation
        return grant
    }

    /// What `signature` covers.
    public var signedBytes: Data {
        PushSigning.message("noodle-push-grant-v1", [sealed, deviceKey, hubKey, PushSigning.bytes(expiresAt)])
    }

    public var hasValidSignature: Bool {
        PushSigning.isValid(signature, by: deviceKey, for: signedBytes)
    }
}

/// `POST /v1/ring`, sent by a Hub for each away device that granted it calls.
public struct PushRingRequest: Codable, Sendable, Equatable {
    public var grant: CallGrant
    /// The Hub's call ID. The phone reports the call to CallKit under it, so a push and an in-app ring
    /// for the same call are one call, and Push rings each device at most once for it.
    public var callID: UUID
    /// How long the call still rings; the phone ends it as unanswered after that.
    public var secondsLeft: Int
    /// Seconds since 1970 when the Hub signed this.
    public var timestamp: Int64
    /// The caller, encrypted with the phone's call key. Push and Apple cannot read it.
    public var blob: Data
    public var signature: Data

    enum CodingKeys: String, CodingKey {
        case grant, callID, secondsLeft, timestamp = "ts", blob, signature = "sig"
    }

    public init(grant: CallGrant, callID: UUID, secondsLeft: Int, timestamp: Int64, blob: Data, signature: Data) {
        self.grant = grant
        self.callID = callID
        self.secondsLeft = secondsLeft
        self.timestamp = timestamp
        self.blob = blob
        self.signature = signature
    }

    /// A ring request signed by the Hub's key, which must be the key `grant` names.
    public static func signed(grant: CallGrant, callID: UUID, secondsLeft: Int, timestamp: Int64, blob: Data,
                              by key: P256.Signing.PrivateKey) throws -> PushRingRequest {
        var request = PushRingRequest(grant: grant, callID: callID, secondsLeft: secondsLeft, timestamp: timestamp,
                                      blob: blob, signature: Data())
        request.signature = try key.signature(for: request.signedBytes).rawRepresentation
        return request
    }

    /// What `signature` covers: the whole grant, including the phone's signature, and every other field.
    public var signedBytes: Data {
        PushSigning.message("noodle-push-ring-v1", [
            grant.signedBytes, grant.signature, PushSigning.bytes(callID), PushSigning.bytes(Int64(secondsLeft)),
            PushSigning.bytes(timestamp), blob,
        ])
    }

    /// Whether the Hub the grant names signed this request.
    public var hasValidSignature: Bool {
        PushSigning.isValid(signature, by: grant.hubKey, for: signedBytes)
    }
}

/// What Push answers a ring with. The HTTP status says the same; the Hub acts on `outcome`.
public struct PushRingResult: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// APNs accepted the push. That is not proof the phone rang.
        case sent
        /// This call already rang this device; nothing was sent again.
        case duplicate
        /// The token is gone (the app was deleted, or the token was replaced): drop the grant.
        case unregistered
        /// The grant expired: keep ringing in-app and wait for the phone to renew it.
        case grantExpired
        /// The sealed token is older than Push accepts (90 days): drop the grant, keep ringing in-app, and
        /// ask the phone to register again and send a new grant on its next connect.
        case registrationExpired
        /// The request or grant is malformed or its signatures do not hold. Retrying will not help.
        case rejected
        /// Too many rings from this address, for this Hub or to this device.
        case rateLimited
        /// APNs could not be reached or refused for a reason of its own. Worth one retry.
        case failed
    }

    public var outcome: Outcome
    /// APNs' HTTP status, when Push got as far as asking.
    public var apnsStatus: Int?
    /// A short reason for logs and tests, such as `staleRequest` or APNs' `BadDeviceToken`.
    public var reason: String?

    public init(outcome: Outcome, apnsStatus: Int? = nil, reason: String? = nil) {
        self.outcome = outcome
        self.apnsStatus = apnsStatus
        self.reason = reason
    }
}

/// The VoIP push's JSON. The phone must report the call to CallKit from this alone, before any networking.
public struct PushCallPayload: Codable, Sendable, Equatable {
    public var callID: UUID
    /// Seconds since 1970 when the call stops ringing.
    public var expiresAt: Int64
    /// `hubHash(for:)` of the key that signed the ring. The phone reports the call at once, then ends it
    /// if no Hub it is paired with has this hash.
    public var hub: Data
    /// `PushRingRequest.blob`, untouched.
    public var blob: Data

    enum CodingKeys: String, CodingKey {
        case callID, expiresAt = "exp", hub, blob
    }

    public init(callID: UUID, expiresAt: Int64, hub: Data, blob: Data) {
        self.callID = callID
        self.expiresAt = expiresAt
        self.hub = hub
        self.blob = blob
    }

    /// SHA-256 of a Hub's `LinkIdentity` public key (x9.63), all 32 bytes.
    public static func hubHash(for hubKey: Data) -> Data {
        Data(SHA256.hash(data: hubKey))
    }
}

/// The signed byte strings: an ASCII domain tag and a zero byte, then each field as a big-endian 32-bit
/// length and its bytes. The tag keeps one kind of signature from passing for another.
public enum PushSigning {
    public static func message(_ domain: String, _ fields: [Data]) -> Data {
        var data = Data(domain.utf8)
        data.append(0)
        for field in fields {
            data.append(bytes(UInt32(field.count)))
            data.append(field)
        }
        return data
    }

    static func bytes<Integer: FixedWidthInteger>(_ value: Integer) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func bytes(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    static func isValid(_ signature: Data, by key: Data, for message: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: key),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
