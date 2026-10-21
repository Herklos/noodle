import CryptoKit
import Foundation
import HubLink
@testable import NoodleMobile
import Synchronization
import Testing

/// The call keys in memory, standing in for the keychain.
private final class MemoryCallKeys: CallKeys {
    var stored: [Data: Data] = [:]
    func key(for hub: Data) -> Data? { stored[hub] }
    func save(_ key: Data, for hub: Data) throws { stored[hub] = key }
    func remove(for hub: Data) { stored[hub] = nil }
    var hubs: [Data] { Array(stored.keys) }
}

/// A Hub that lets devices give it call grants, reached over QUIC like the real one.
private actor GrantingHub {
    var pushes: [LinkCallPush] = []
    /// What the Hub keeps, as its status tells the phone.
    var expiresAt: Date?
    var ringsThroughPush = true
    /// Where it listens, which it tells the phone when pairing, as the real Hub does.
    var endpoints: [LinkEndpoint] = []

    func listen(at endpoint: LinkEndpoint) { endpoints = [endpoint] }
    /// Grants the phone sent, kept or not; one that refuses them all, as with its clock far off.
    var attempts = 0
    var refuses = false

    func refuse() { refuses = true }

    func keep(_ push: LinkCallPush) {
        pushes.append(push)
        expiresAt = push.grant.map { Date(timeIntervalSince1970: TimeInterval($0.expiresAt)) }
    }

    func drop() { expiresAt = nil }
    func expire(at date: Date) { expiresAt = date }

    func reply(to data: Data) -> LinkResponse {
        switch LinkProtocol.decode(data) {
        case .success(.enroll), .success(.status):
            return .status(LinkStatus(hubName: "Studio", userName: "Petko", planName: "", harnesses: [], endpoints: endpoints,
                                      ringsThroughPush: ringsThroughPush, callPushExpiresAt: expiresAt))
        case .success(.callPush(let push)):
            attempts += 1
            if refuses { return .failure("The call grant has expired or lasts too long.") }
            keep(push)
            return .done
        default:
            return .failure("Not here.")
        }
    }
}

/// Stands in for Noodle Push's register endpoint.
private final class FakeRegistrations: Sendable {
    private let received = Mutex<[PushRegistration]>([])
    var all: [PushRegistration] { received.withLock { $0 } }

    func post(_ url: URL, _ body: Data) throws -> (Int, Data) {
        guard url.absoluteString == "https://push.usenoodle.app/v1/register",
              let registration = try? JSONDecoder().decode(PushRegistration.self, from: body) else { return (400, Data()) }
        let count = received.withLock { $0.append(registration); return $0.count }
        return (200, try JSONEncoder().encode(PushRegistered(sealed: Data("sealed \(count)".utf8))))
    }
}

@MainActor @Suite struct CallPushTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let token = Data(repeating: 0xAB, count: 32)

    private func paired(to hub: GrantingHub) async throws -> (HubPairing, LinkIdentity, LinkServer) {
        let identity = LinkIdentity()
        let server = try LinkServer(identity: identity, port: 0, admits: { _ in true }) { _, data in
            .response(LinkProtocol.encode(await hub.reply(to: data)))
        }
        try await server.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: try #require(server.port))
        await hub.listen(at: endpoint)
        let invitation = LinkInvitation(hubName: "Studio", hubKey: identity.publicKey, endpoints: [endpoint], userName: "Petko",
                                        joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date().addingTimeInterval(600))
        let pairing = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 deviceName: "iPhone")
        await pairing.join(invitation.url().absoluteString)
        try #require(pairing.hub != nil)
        return (pairing, identity, server)
    }

    private func status(expires: Date?, rings: Bool = true) -> LinkStatus {
        LinkStatus(hubName: "Hub", userName: "Petko", planName: "", harnesses: [], endpoints: [], ringsThroughPush: rings,
                   callPushExpiresAt: expires)
    }

    /// When the phone registers with Push and grants a Hub: once, then again only as the grant nears its end,
    /// the token or its environment changes, the sealed token ages, the phone lost the Hub's call key, or the
    /// Hub dropped what it had; never again within minutes of a grant, nor registering anew within the hour.
    @Test func aGrantIsRenewedWhenNeededAndNeverInAStorm() {
        let record = CallPushRecord(sealed: Data([1]), registeredAt: now, token: Data(SHA256.hash(data: token)), environment: .production)
        let fresh = now.addingTimeInterval(13 * 86_400), near = now.addingTimeInterval(6 * 86_400)
        let hour = now.addingTimeInterval(2 * 3600)
        func step(token: Data? = token, environment: PushAPNsEnvironment = .production, record: CallPushRecord? = record,
                  status: LinkStatus?, hasKey: Bool = true, at date: Date? = nil) -> CallPushes.Step {
            CallPushes.step(token: token, environment: environment, record: record, status: status, hasKey: hasKey, now: date ?? now)
        }
        #expect(step(record: nil, status: status(expires: nil)) == .register)
        #expect(step(status: status(expires: fresh)) == .none)
        #expect(step(status: status(expires: near)) == .grant)
        #expect(step(status: status(expires: fresh), hasKey: false) == .grant, "Lost the Hub's call key")
        #expect(step(status: status(expires: nil), at: hour) == .register, "The Hub dropped the grant, as when Push no longer rings the token")
        #expect(step(status: status(expires: nil)) == .grant, "Registered within the hour: grant the same sealed token again")
        #expect(step(token: Data(repeating: 1, count: 32), status: status(expires: fresh)) == .register, "A new token")
        #expect(step(environment: .sandbox, status: status(expires: fresh)) == .register)
        #expect(step(status: status(expires: now.addingTimeInterval(70 * 86_400)), at: now.addingTimeInterval(61 * 86_400)) == .register,
                "Registered again well before Push refuses a sealed token at 90 days")
        #expect(step(token: nil, status: status(expires: fresh)) == .stop, "iOS took the token back")
        #expect(step(token: nil, status: status(expires: nil)) == .none)
        #expect(step(status: status(expires: nil, rings: false)) == .none, "A Hub from before")
        #expect(step(status: nil) == .none)

        var granted = record
        granted.grantedAt = now
        #expect(step(record: granted, status: status(expires: nil), at: now.addingTimeInterval(600)) == .none,
                "The Hub refused it or its status is behind: wait")
        #expect(step(record: granted, status: status(expires: near), at: now.addingTimeInterval(600)) == .none)
        #expect(step(record: granted, status: status(expires: nil), at: now.addingTimeInterval(1_000)) == .grant)
        #expect(step(record: granted, status: status(expires: nil), at: hour) == .register)
    }

    /// A Hub that keeps refusing grants, as with its clock far off, costs one registration and a grant every
    /// quarter of an hour, not one every check-in.
    @Test func aHubRefusingGrantsCausesNoRegistrationStorm() async throws {
        let hub = GrantingHub(), registrations = FakeRegistrations()
        let (pairing, _, server) = try await paired(to: hub)
        defer { server.stop() }
        await hub.refuse()
        let pushes = CallPushes(environment: .production, keys: MemoryCallKeys(), hubs: { [] }, post: { try registrations.post($0, $1) })
        pushes.token = token
        for minute in stride(from: 0, to: 60, by: 1) { await pushes.renew([pairing], now: now.addingTimeInterval(Double(minute) * 60)) }
        #expect(registrations.all.count == 1)
        #expect(await hub.attempts == 4)
    }

    /// The phone registers its token with Push signed with the key it paired with the Hub, and grants that Hub
    /// alone the sealed token and a call key of its own; it renews without registering, and registers again
    /// once the Hub dropped the grant.
    @Test func thePhoneRegistersAndGrantsEachHubWithItsPairingKey() async throws {
        let hub = GrantingHub(), registrations = FakeRegistrations(), keys = MemoryCallKeys()
        let (pairing, hubIdentity, server) = try await paired(to: hub)
        defer { server.stop() }
        let pushes = CallPushes(environment: .sandbox, keys: keys, hubs: { [] }, post: { try registrations.post($0, $1) })
        await pushes.renew([pairing], now: now)
        #expect(await hub.pushes.isEmpty, "No token yet")

        pushes.token = token
        await pushes.renew([pairing], now: now)
        let registration = try #require(registrations.all.first)
        #expect(registration.hasValidSignature)
        #expect(registration.token == token)
        #expect(registration.environment == .sandbox)
        let sent = try #require(await hub.pushes.first)
        let grant = try #require(sent.grant)
        #expect(grant.hasValidSignature)
        #expect(grant.deviceKey == registration.deviceKey, "Signed with the key the token was sealed to, as Push checks")
        #expect(grant.hubKey == hubIdentity.publicKey.x963)
        #expect(grant.sealed == Data("sealed 1".utf8))
        #expect(grant.expiresAt == Int64(now.timeIntervalSince1970 + 14 * 86_400))
        let hubHash = PushCallPayload.hubHash(for: hubIdentity.publicKey.x963)
        #expect(sent.callKey == keys.stored[hubHash])
        #expect(sent.callKey?.count == 32)
        #expect(pairing.status?.callPushExpiresAt == Date(timeIntervalSince1970: TimeInterval(grant.expiresAt)))

        await pushes.renew([pairing], now: now.addingTimeInterval(3600))
        #expect(await hub.pushes.count == 1, "Nothing to renew yet")

        let later = now.addingTimeInterval(8 * 86_400)
        await pushes.renew([pairing], now: later)
        #expect(await hub.pushes.count == 2)
        #expect(registrations.all.count == 1, "Renewed with the token sealed before")
        #expect(await hub.pushes.last?.callKey == sent.callKey)

        await hub.drop()
        await pairing.refresh(quietly: true)
        await pushes.renew([pairing], now: later.addingTimeInterval(20 * 60))
        #expect(registrations.all.count == 2)
        #expect(await hub.pushes.last?.grant?.sealed == Data("sealed 2".utf8))

        pushes.token = nil
        await pushes.renew([pairing], now: later.addingTimeInterval(40 * 60))
        #expect(await hub.pushes.last == LinkCallPush(grant: nil, callKey: nil), "Told to stop once iOS took the token back")

        await pushes.renew([], now: later.addingTimeInterval(41 * 60))
        #expect(keys.stored.isEmpty, "The key goes with the Hub")
    }

    /// A push is reported straight away from what it carries: a call from a Hub the phone is in rings with the
    /// bot's name; one from any other Hub, unreadable, or too late is reported and ended.
    @Test func aPushRingsOnlyForAHubThePhoneIsInAndOnlyWithItsCallersKey() throws {
        let hubKey = LinkIdentity().publicKey, otherKey = LinkIdentity().publicKey
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let studio = PushedHub(folder: folder, name: "Studio", key: hubKey)
        let keys = MemoryCallKeys(), callKey = Data(repeating: 9, count: 32), id = UUID()
        try keys.save(callKey, for: PushCallPayload.hubHash(for: hubKey.x963))
        let caller = LinkCallPushCaller(botID: UUID(), botName: "Kai", conversationID: UUID())
        func payload(hub: LinkPublicKey = hubKey, expires: TimeInterval = 40, blob: Data? = nil) throws -> [AnyHashable: Any] {
            let pushed = PushCallPayload(callID: id, expiresAt: Int64(now.timeIntervalSince1970 + expires),
                                         hub: PushCallPayload.hubHash(for: hub.x963),
                                         blob: try blob ?? caller.sealed(callID: id, with: callKey))
            return try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(pushed)) as? [AnyHashable: Any])
        }
        func answer(_ dictionary: [AnyHashable: Any]) -> CallPushes.Answer {
            CallPushes.answer(to: dictionary, hubs: [studio], keys: keys, now: now)
        }

        #expect(answer(try payload()) == .ring(PushedCall(id: id, caller: caller, hub: studio, secondsLeft: 40)))
        #expect(answer(try payload(hub: otherKey)) == .refuse(id), "Not a Hub this phone is in")
        #expect(answer(try payload(expires: -1)) == .refuse(id), "Stopped ringing before it arrived")
        #expect(answer(try payload(blob: try caller.sealed(callID: UUID(), with: callKey))) == .refuse(id), "Sealed for another call")
        #expect(answer(try payload(blob: Data([1, 2, 3]))) == .refuse(id))
        // The Hub's own end of the ring, sealed with the caller, wins when it is earlier.
        let soon = LinkCallPushCaller(botID: caller.botID, botName: "Kai", conversationID: caller.conversationID,
                                      expiresAt: Int64(now.timeIntervalSince1970) + 10)
        #expect(answer(try payload(blob: try soon.sealed(callID: id, with: callKey))) == .ring(PushedCall(id: id, caller: soon, hub: studio, secondsLeft: 10)))
        let over = LinkCallPushCaller(botID: caller.botID, botName: "Kai", conversationID: caller.conversationID,
                                      expiresAt: Int64(now.timeIntervalSince1970) - 1)
        #expect(answer(try payload(blob: try over.sealed(callID: id, with: callKey))) == .refuse(id), "The Hub stopped ringing it")
        keys.remove(for: PushCallPayload.hubHash(for: hubKey.x963))
        #expect(answer(try payload()) == .refuse(id), "No key for that Hub")
        guard case .refuse = answer(["aps": [String: Any]()]) else { Issue.record("An unreadable push still has to be reported"); return }
    }

    /// The build decides which of Apple's hosts its token is for: Xcode's development profile is the sandbox,
    /// TestFlight and the App Store, which carry no profile, production.
    @Test func theProvisioningProfileChoosesTheAPNsEnvironment() {
        let profile = { (value: String) in
            Data("0\u{82}\u{0}<?xml version=\"1.0\"?><plist><dict><key>Entitlements</key><dict><key>aps-environment</key>\n\t\t<string>\(value)</string></dict></dict></plist>".utf8)
        }
        #expect(CallPushEnvironment.environment(profile: profile("development")) == .sandbox)
        #expect(CallPushEnvironment.environment(profile: profile("production")) == .production)
        #expect(CallPushEnvironment.environment(profile: nil) == .production)
        #expect(CallPushEnvironment.environment(profile: Data("no entitlements".utf8)) == .production)
    }

    /// Only the build Noodle Push's VoIP topic is for listens for VoIP pushes; Noodle Dev's bundle ID is not it.
    @Test func onlyTheReleaseBundleIDListensForVoIPPushes() {
        #expect(CallPushEnvironment.servedBundleID == "com.pdparchitect.noodle.mobile")
        let pushes = CallPushes(keys: MemoryCallKeys(), hubs: { [] })
        pushes.start(bundleID: "com.pdparchitect.noodle.mobile.local")
        #expect(!pushes.isListening)
    }
}
