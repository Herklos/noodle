import Crypto
import Foundation
import Logging
import PushWire

/// An HTTP answer, without tying the logic to a server framework.
public struct PushHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    init(status: Int, json: some Encodable) {
        self.status = status
        body = (try? JSONEncoder().encode(json)) ?? Data("{}".utf8)
    }
}

/// The two endpoints. Push keeps no database: only rate-limit buckets and recent call IDs, in memory.
///
/// Logs carry the route, the outcome, APNs' status and latency, and a short hash of the Hub key. Never
/// tokens, sealed tokens, grants, signatures, payloads or request bodies.
public actor PushService {
    private let sealer: TokenSealer
    private let sender: any VoIPSending
    private let limits: PushLimits
    private let logger: Logger
    private var hubRings: RateLimiter
    private var deviceRings: RateLimiter
    private var registrations: RateLimiter
    private var calls: CallMemory

    public init(sealer: TokenSealer, sender: any VoIPSending, limits: PushLimits = PushLimits(), logger: Logger) {
        self.sealer = sealer
        self.sender = sender
        self.limits = limits
        self.logger = logger
        hubRings = RateLimiter(perMinute: limits.ringsPerHubPerMinute)
        deviceRings = RateLimiter(perMinute: limits.ringsPerDevicePerMinute)
        registrations = RateLimiter(perMinute: limits.registrationsPerAddressPerMinute)
        calls = CallMemory(lifetime: limits.callMemory)
    }

    // MARK: Register

    struct Failure: Codable { var error: String }

    /// `POST /v1/register`: checks the phone holds the key it names and seals its token to that key.
    /// `address` is the client's IP, as the Worker forwards it, for the per-address limit.
    public func register(_ body: Data, address: String, now: Date = Date()) -> PushHTTPResponse {
        let response = registerResponse(body, address: address, now: now)
        logger.info("register", metadata: ["status": "\(response.status)"])
        return response
    }

    private func registerResponse(_ body: Data, address: String, now: Date) -> PushHTTPResponse {
        guard registrations.allow(address, now: now) else {
            return PushHTTPResponse(status: 429, json: Failure(error: "rateLimited"))
        }
        guard let registration = try? JSONDecoder().decode(PushRegistration.self, from: body),
              (1...limits.largestToken).contains(registration.token.count),
              (try? P256.Signing.PublicKey(x963Representation: registration.deviceKey)) != nil else {
            return PushHTTPResponse(status: 400, json: Failure(error: "malformed"))
        }
        guard isFresh(registration.timestamp, now: now) else {
            return PushHTTPResponse(status: 401, json: Failure(error: "staleRequest"))
        }
        guard registration.hasValidSignature else {
            return PushHTTPResponse(status: 401, json: Failure(error: "badSignature"))
        }
        let destination = SealedDestination(token: registration.token, environment: registration.environment,
                                            deviceKeyHash: Data(SHA256.hash(data: registration.deviceKey)),
                                            issuedAt: Int64(now.timeIntervalSince1970))
        guard let sealed = try? sealer.seal(destination) else {
            return PushHTTPResponse(status: 500, json: Failure(error: "sealFailed"))
        }
        return PushHTTPResponse(status: 200, json: PushRegistered(sealed: sealed))
    }

    // MARK: Ring

    /// `POST /v1/ring`: rings the phone a Hub's grant points at, after checking, in order, that the token
    /// opens, the phone signed the grant, the grant is current, the Hub it names signed the request, the
    /// request is fresh and new for this device, and neither the Hub nor the phone is over its limit.
    public func ring(_ body: Data, now: Date = Date()) async -> PushHTTPResponse {
        let started = ContinuousClock.now
        guard let request = try? JSONDecoder().decode(PushRingRequest.self, from: body) else {
            return answer(.rejected, "malformed", status: 400, hub: nil, started: started)
        }
        let hub = Self.shortHash(request.grant.hubKey)
        guard (1...limits.longestRing).contains(request.secondsLeft), request.blob.count <= limits.largestBlob else {
            return answer(.rejected, "malformed", status: 400, hub: hub, started: started)
        }
        guard let destination = sealer.open(request.grant.sealed) else {
            return answer(.rejected, "badSealedToken", status: 401, hub: hub, started: started)
        }
        guard request.grant.hasValidSignature,
              Data(SHA256.hash(data: request.grant.deviceKey)) == destination.deviceKeyHash else {
            return answer(.rejected, "badGrant", status: 401, hub: hub, started: started)
        }
        let seconds = Int64(now.timeIntervalSince1970)
        guard request.grant.expiresAt > seconds else {
            return answer(.grantExpired, "grantExpired", status: 403, hub: hub, started: started)
        }
        guard request.grant.expiresAt <= seconds + limits.longestGrant else {
            return answer(.rejected, "grantTooLong", status: 403, hub: hub, started: started)
        }
        guard request.hasValidSignature else {
            return answer(.rejected, "badSignature", status: 401, hub: hub, started: started)
        }
        guard isFresh(request.timestamp, now: now) else {
            return answer(.rejected, "staleRequest", status: 401, hub: hub, started: started)
        }
        // A Hub rings each of a person's devices with the same call ID, so the memory is per device.
        let device = destination.deviceKeyHash.base64EncodedString()
        let call = device + "/" + request.callID.uuidString
        guard calls.remember(call, now: now) else {
            return answer(.duplicate, nil, status: 200, hub: hub, started: started)
        }
        let hubKey = request.grant.hubKey.base64EncodedString()
        guard hubRings.allow(hubKey, now: now) else {
            calls.forget(call)
            return answer(.rateLimited, "hubLimit", status: 429, hub: hub, started: started)
        }
        guard deviceRings.allow(device, now: now) else {
            calls.forget(call)
            hubRings.refund(hubKey)
            return answer(.rateLimited, "deviceLimit", status: 429, hub: hub, started: started)
        }

        let payload = PushCallPayload(callID: request.callID, expiresAt: seconds + Int64(request.secondsLeft),
                                      blob: request.blob)
        let delivery = await sender.send(VoIPPush(token: destination.token, environment: destination.environment,
                                                  payload: payload))
        switch delivery {
        case .sent:
            return answer(.sent, nil, status: 200, hub: hub, started: started, apns: 200)
        case .refused(let status, let reason) where Self.meansTokenGone(status: status, reason: reason):
            return answer(.unregistered, reason, status: 410, hub: hub, started: started, apns: status)
        case .refused(let status, let reason):
            // Nothing rang, so a retry may ring once APNs recovers, and this one does not count.
            calls.forget(call)
            hubRings.refund(hubKey)
            deviceRings.refund(device)
            return answer(.failed, reason, status: status >= 500 || status == 429 ? 503 : 502, hub: hub,
                          started: started, apns: status)
        case .unreachable:
            calls.forget(call)
            hubRings.refund(hubKey)
            deviceRings.refund(device)
            return answer(.failed, "apnsUnreachable", status: 503, hub: hub, started: started)
        }
    }

    /// APNs' answers that mean this token will never ring again: 410, or a token APNs does not know for
    /// this topic and host. The Hub drops the grant and waits for the phone to register again.
    static func meansTokenGone(status: Int, reason: String?) -> Bool {
        status == 410 || (status == 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason ?? ""))
    }

    private func answer(_ outcome: PushRingResult.Outcome, _ reason: String?, status: Int, hub: String?,
                        started: ContinuousClock.Instant, apns: Int? = nil) -> PushHTTPResponse {
        let elapsed = ContinuousClock.now - started
        var metadata: Logger.Metadata = ["status": "\(status)", "outcome": "\(outcome.rawValue)",
                                         "ms": "\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)"]
        if let hub { metadata["hub"] = "\(hub)" }
        if let apns { metadata["apns"] = "\(apns)" }
        if let reason { metadata["reason"] = "\(reason)" }
        logger.info("ring", metadata: metadata)
        return PushHTTPResponse(status: status, json: PushRingResult(outcome: outcome, apnsStatus: apns, reason: reason))
    }

    private func isFresh(_ timestamp: Int64, now: Date) -> Bool {
        // Compared without subtracting, which a hostile timestamp could overflow.
        let seconds = Int64(now.timeIntervalSince1970)
        return (seconds - limits.clockSkew...seconds + limits.clockSkew).contains(timestamp)
    }

    /// Enough of a key's hash to tell Hubs apart in logs, not enough to matter.
    static func shortHash(_ key: Data) -> String {
        SHA256.hash(data: key).prefix(4).map { byte in
            let digits = Array("0123456789abcdef")
            return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
        }.joined()
    }
}
