import Crypto
import Foundation
import Logging
@testable import PushCore
import PushWire

/// Records pushes instead of sending them, and answers with `delivery`.
actor RecordingSender: VoIPSending {
    private(set) var pushes: [VoIPPush] = []
    var delivery: VoIPDelivery = .sent

    func answer(_ delivery: VoIPDelivery) { self.delivery = delivery }

    func send(_ push: VoIPPush) async -> VoIPDelivery {
        pushes.append(push)
        return delivery
    }
}

/// Keeps every log line, with its metadata, so tests can look for secrets in them.
final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }

    func append(_ line: String) { lock.withLock { storage.append(line) } }

    var logger: Logger {
        Logger(label: "test") { _ in RecordingHandler(recorder: self) }
    }
}

struct RecordingHandler: LogHandler {
    let recorder: LogRecorder
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { $1 }
        recorder.append("\(event.message) \(merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    }
}

/// A phone, a Hub and a Push service with a fixed clock.
struct Fixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sealKey = SymmetricKey(size: .bits256)
    let phone = P256.Signing.PrivateKey()
    let hub = P256.Signing.PrivateKey()
    let token = Data((0..<32).map { UInt8(255 - $0) })
    let sender = RecordingSender()
    let logs = LogRecorder()
    let service: PushService

    init(limits: PushLimits = PushLimits()) {
        service = PushService(sealer: try! TokenSealer(key: sealKey), sender: sender, limits: limits, logger: logs.logger)
    }

    var seconds: Int64 { Int64(now.timeIntervalSince1970) }

    func sealed(token: Data? = nil, environment: PushAPNsEnvironment = .production,
                for key: P256.Signing.PrivateKey? = nil) throws -> Data {
        let deviceKey = (key ?? phone).publicKey.x963Representation
        return try TokenSealer(key: sealKey).seal(SealedDestination(
            token: token ?? self.token, environment: environment,
            deviceKeyHash: Data(SHA256.hash(data: deviceKey)), issuedAt: seconds))
    }

    func grant(sealed: Data? = nil, hub: P256.Signing.PrivateKey? = nil, expiresIn: Int64 = 14 * 86_400,
               by phone: P256.Signing.PrivateKey? = nil) throws -> CallGrant {
        try CallGrant.signed(sealed: sealed ?? self.sealed(), hubKey: (hub ?? self.hub).publicKey.x963Representation,
                             expiresAt: seconds + expiresIn, by: phone ?? self.phone)
    }

    func ring(_ grant: CallGrant? = nil, callID: UUID = UUID(), secondsLeft: Int = 45, skew: Int64 = 0,
              signer: P256.Signing.PrivateKey? = nil) throws -> Data {
        try JSONEncoder().encode(PushRingRequest.signed(
            grant: grant ?? self.grant(), callID: callID, secondsLeft: secondsLeft, timestamp: seconds + skew,
            blob: Data("encrypted caller".utf8), by: signer ?? hub))
    }

    func result(_ response: PushHTTPResponse) throws -> PushRingResult {
        try JSONDecoder().decode(PushRingResult.self, from: response.body)
    }
}
