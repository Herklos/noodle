import Crypto
import Foundation

public struct PushConfigurationError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The limits Push enforces. Clients choose none of them.
public struct PushLimits: Sendable {
    /// How far a request's `ts` may be from Push's clock, either way.
    public var clockSkew: Int64 = 60
    /// The longest grant Push accepts, whatever the phone signed. The phone asks for about 14 days and
    /// renews on every connect; the extra day covers clock differences.
    public var longestGrant: Int64 = 15 * 86_400
    /// The oldest sealed token Push still rings; older ones get `registrationExpired`, so a token taken
    /// once cannot ring forever, and the phone registers again.
    public var oldestRegistration: Int64 = 90 * 86_400
    /// The longest a call may still ring.
    public var longestRing = 300
    public var largestBlob = 2_048
    public var largestToken = 200
    /// Rings per minute from one address (an IPv4 address or an IPv6 /64), checked before any parsing
    /// or cryptography. The Worker applies the same limit at Cloudflare's edge first.
    public var ringsPerAddressPerMinute = 30.0
    /// Rings per minute for one Hub key, across all its devices.
    public var ringsPerHubPerMinute = 10.0
    /// Rings per minute to one phone (its token and environment, however many keys registered it), from
    /// all its Hubs.
    public var ringsPerDevicePerMinute = 3.0
    /// Rings per minute from one Hub to one phone, below the phone's own limit, so one Hub cannot use up
    /// a phone's rings for the others.
    public var ringsPerHubPerDevicePerMinute = 2.0
    /// Registrations per minute from one address (an IPv4 address or an IPv6 /64).
    public var registrationsPerAddressPerMinute = 10.0
    /// The most keys each rate limit and the call memory track; the least recently used go first.
    public var trackedKeys = 10_000
    /// How long a call ID is remembered per device; longer than the window `clockSkew` allows.
    public var callMemory: TimeInterval = 300
    /// How long Push waits for APNs before telling the Hub it failed. The Hub gives up after 10 s.
    public var apnsTimeout: Duration = .seconds(8)

    public init() {}
}

/// What the server reads from its environment. The Worker passes the secrets in (`worker/src/index.ts`).
public struct PushConfiguration: Sendable {
    public var sealKey: SymmetricKey
    public var apnsKey: P256.Signing.PrivateKey
    public var apnsKeyID: String
    public var teamID: String
    /// `com.pdparchitect.noodle.mobile.voip`: the Mobile bundle ID plus `.voip`.
    public var topic: String
    public var port: Int
    public var limits = PushLimits()

    public init(sealKey: SymmetricKey, apnsKey: P256.Signing.PrivateKey, apnsKeyID: String, teamID: String,
                topic: String, port: Int = 8080) {
        self.sealKey = sealKey
        self.apnsKey = apnsKey
        self.apnsKeyID = apnsKeyID
        self.teamID = teamID
        self.topic = topic
        self.port = port
    }

    /// Reads `PUSH_SEAL_KEY` (base64 of 32 random bytes), `APNS_KEY_P8` (the .p8 file's PEM text),
    /// `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` and `PORT`. Errors name the variable, never its value.
    public init(environment: [String: String]) throws {
        func required(_ name: String) throws -> String {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw PushConfigurationError("\(name) is not set.")
            }
            return value
        }
        guard let seal = Data(base64Encoded: try required("PUSH_SEAL_KEY")), seal.count == 32 else {
            throw PushConfigurationError("PUSH_SEAL_KEY must be base64 of 32 bytes.")
        }
        let apnsKey: P256.Signing.PrivateKey
        do {
            apnsKey = try P256.Signing.PrivateKey(pemRepresentation: Self.pem(try required("APNS_KEY_P8")))
        } catch let error as PushConfigurationError {
            throw error
        } catch {
            throw PushConfigurationError("APNS_KEY_P8 is not a .p8 key.")
        }
        guard let port = Int(environment["PORT"] ?? "8080") else { throw PushConfigurationError("PORT is not a number.") }
        self.init(sealKey: SymmetricKey(data: seal), apnsKey: apnsKey, apnsKeyID: try required("APNS_KEY_ID"),
                  teamID: try required("APNS_TEAM_ID"),
                  topic: environment["APNS_TOPIC"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.pdparchitect.noodle.mobile.voip",
                  port: port)
    }

    /// Secret stores sometimes keep a PEM's line breaks as `\n`, or the whole file as base64.
    static func pem(_ value: String) -> String {
        if value.contains("-----BEGIN") { return value.replacingOccurrences(of: "\\n", with: "\n") }
        if let data = Data(base64Encoded: value), let text = String(data: data, encoding: .utf8) { return text }
        return value
    }
}
