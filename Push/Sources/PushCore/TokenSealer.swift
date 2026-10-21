import Crypto
import Foundation
import PushWire

/// A VoIP token as only Push sees it, after opening `PushRegistered.sealed`.
public struct SealedDestination: Codable, Sendable, Equatable {
    public var token: Data
    public var environment: PushAPNsEnvironment
    /// SHA-256 of the phone key that registered the token; a grant must be signed by that key.
    public var deviceKeyHash: Data
    /// Seconds since 1970 when Push sealed it.
    public var issuedAt: Int64

    enum CodingKeys: String, CodingKey {
        case token, environment = "env", deviceKeyHash = "dkh", issuedAt = "iat"
    }

    public init(token: Data, environment: PushAPNsEnvironment, deviceKeyHash: Data, issuedAt: Int64) {
        self.token = token
        self.environment = environment
        self.deviceKeyHash = deviceKeyHash
        self.issuedAt = issuedAt
    }
}

/// Seals tokens with `PUSH_SEAL_KEY` (AES-256-GCM), so Push can hand them out and store nothing.
///
/// Layout: a format byte, then the GCM nonce, ciphertext and tag. The format byte is also the
/// authenticated data, and is where a key ID goes when the seal key starts rotating.
public struct TokenSealer: Sendable {
    static let format: UInt8 = 1
    private let key: SymmetricKey

    public init(key: SymmetricKey) throws {
        guard key.bitCount == 256 else { throw PushConfigurationError("PUSH_SEAL_KEY must be 32 bytes.") }
        self.key = key
    }

    public func seal(_ destination: SealedDestination) throws -> Data {
        let box = try AES.GCM.seal(try JSONEncoder().encode(destination), using: key,
                                   authenticating: Data([Self.format]))
        guard let combined = box.combined else { throw PushConfigurationError("Could not seal the token.") }
        return Data([Self.format]) + combined
    }

    /// The destination inside `sealed`, or nil when this key did not seal it or it was changed.
    public func open(_ sealed: Data) -> SealedDestination? {
        guard sealed.first == Self.format,
              let box = try? AES.GCM.SealedBox(combined: Data(sealed.dropFirst())),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Data([Self.format])) else { return nil }
        return try? JSONDecoder().decode(SealedDestination.self, from: plain)
    }
}
