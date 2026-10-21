import CryptoKit
import Foundation
import HubLink
import os
import PushKit
import Security
import UIKit
import UserNotifications

// Calls from bots ring the phone through Noodle Push while Noodle is closed or away from its Hub: the
// phone registers its VoIP token with Push, gives each Hub a grant to ring it and a key to say who is
// calling, and reports each VoIP push to the call screen the moment it arrives, as iOS requires.

/// Which APNs host the phone's VoIP token belongs to, and whether this build can be rung at all.
enum CallPushEnvironment {
    /// The bundle ID Noodle Push's VoIP topic belongs to. A build with another, such as Noodle Dev, gets
    /// tokens for a topic Push does not send to, so it does not register.
    static let servedBundleID = "com.pdparchitect.noodle.mobile"

    static func current(bundle: Bundle = .main) -> PushAPNsEnvironment {
        environment(profile: bundle.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) })
    }

    /// A build Xcode installs carries its provisioning profile, whose `aps-environment` says `development`
    /// for Apple's sandbox. TestFlight and the App Store carry none, and push in production.
    static func environment(profile: Data?) -> PushAPNsEnvironment {
        guard let profile, let text = String(data: profile, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>") else { return .production }
        return text[key.upperBound...].prefix(200).contains("<string>development</string>") ? .sandbox : .production
    }
}

/// The key each Hub encrypts who is calling with, by the hash of the Hub's key, which is how a push names
/// its Hub. Readable once the phone has been unlocked after starting, so a push reads it while locked.
protocol CallKeys: AnyObject {
    func key(for hub: Data) -> Data?
    func save(_ key: Data, for hub: Data) throws
    func remove(for hub: Data)
    var hubs: [Data] { get }
}

/// The call keys in the keychain, on this phone only.
final class KeychainCallKeys: CallKeys {
    private let service = "Noodle call keys"

    private func query(_ hub: Data? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        if let hub { query[kSecAttrAccount] = hub.base64EncodedString() }
        return query
    }

    func key(for hub: Data) -> Data? {
        var query = query(hub)
        query[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func save(_ key: Data, for hub: Data) throws {
        remove(for: hub)
        var item = query(hub)
        item[kSecValueData] = key
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw LinkError("The call key could not be kept (\(status)).") }
    }

    func remove(for hub: Data) { SecItemDelete(query(hub) as CFDictionary) }

    var hubs: [Data] {
        var query = query()
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return [] }
        return items.compactMap { ($0[kSecAttrAccount] as? String).flatMap { Data(base64Encoded: $0) } }
    }
}

/// What the phone last registered with Push for one Hub, kept in that Hub's folder: the sealed token it
/// grants that Hub, and what it was sealed from, to know when to register again.
struct CallPushRecord: Codable, Equatable {
    var sealed: Data
    var registeredAt: Date
    /// SHA-256 of the VoIP token, which is all the phone needs to tell a new one.
    var token: Data
    var environment: PushAPNsEnvironment
    /// When the phone last gave the Hub a grant for it, and until when that grant lasts, so it does not send
    /// another at every check while the Hub's status is behind or the Hub keeps refusing it.
    var grantedAt: Date?
    var grantExpiresAt: Date?

    static func load(from folder: URL) -> CallPushRecord? {
        try? JSONDecoder().decode(CallPushRecord.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))
    }

    func save(to folder: URL) {
        try? JSONEncoder().encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: [.atomic])
    }

    static func remove(from folder: URL) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName)) }

    private static let fileName = "call-push.json"
}

/// A Hub the phone joined, as a push is checked against it before the app has anything else open.
struct PushedHub: Equatable {
    let folder: URL
    let name: String
    let key: LinkPublicKey

    /// The Hubs kept in `hubs`, read straight from their folders. One the phone is leaving is not among them.
    @MainActor static func all(in hubs: URL?) -> [PushedHub] {
        guard let hubs else { return [] }
        let folders = (try? FileManager.default.contentsOfDirectory(at: hubs, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard !HubPairing.isLeaving(folder),
                  let hub = try? JSONDecoder().decode(HubPairing.Hub.self, from: Data(contentsOf: folder.appendingPathComponent("hub.json")))
            else { return nil }
            return PushedHub(folder: folder, name: hub.name, key: hub.key)
        }
    }
}

/// A call a push rings: who calls, on which Hub, for how much longer.
struct PushedCall: Equatable {
    let id: UUID
    let caller: LinkCallPushCaller
    let hub: PushedHub
    let secondsLeft: TimeInterval
}

@MainActor final class CallPushes: NSObject, @preconcurrency PKPushRegistryDelegate {
    static let shared = CallPushes()

    enum Step: Equatable {
        case none
        /// Register the token with Push and send the Hub a grant for it.
        case register
        /// Send the Hub a new grant for the token registered before.
        case grant
        /// Tell the Hub to stop: the phone has no token any more.
        case stop
    }

    /// What a push asks of the call screen.
    enum Answer: Equatable {
        case ring(PushedCall)
        /// Report it, as every VoIP push must be, and end it at once: unreadable, too late, or from a Hub
        /// the phone is not in.
        case refuse(UUID)
    }

    /// A sealed token older than this is registered again at the next renewal; Push refuses them at 90 days.
    static let registrationAge: TimeInterval = 60 * 86_400
    /// How long a Hub that failed to take a grant, or Push that failed to register, is left before trying again.
    static let retryDelay: TimeInterval = 15 * 60

    /// The phone's VoIP token, once PushKit gives it; nil before, or after iOS took it back.
    var token: Data? {
        didSet { if token != oldValue { tokenChanges += 1 } }
    }
    private var tokenChanges = 0
    private let environment: PushAPNsEnvironment
    private let keys: any CallKeys
    private let screen: PhoneCallScreen
    private let hubs: @MainActor () -> [PushedHub]
    private let post: @Sendable (URL, Data) async throws -> (Int, Data)
    private var registry: PKPushRegistry?
    private var retryAfter: [URL: Date] = [:]
    private var sessions: [UUID: PushedCallSession] = [:]

    init(environment: PushAPNsEnvironment = CallPushEnvironment.current(), keys: any CallKeys = KeychainCallKeys(),
         screen: PhoneCallScreen = .shared, hubs: @escaping @MainActor () -> [PushedHub] = { PushedHub.all(in: AppGroup.hubs) },
         post: @escaping @Sendable (URL, Data) async throws -> (Int, Data) = CallPushes.postToPush) {
        self.environment = environment
        self.keys = keys
        self.screen = screen
        self.hubs = hubs
        self.post = post
    }

    /// Listens for VoIP pushes from launch, so one that launched the app is reported at once. Only a build
    /// with the bundle ID Push sends to, on a phone with a call screen for apps.
    func start(bundleID: String? = Bundle.main.bundleIdentifier) {
        guard registry == nil, bundleID == CallPushEnvironment.servedBundleID, screen.isAvailable else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    var isListening: Bool { registry != nil }

    // MARK: Grants

    /// Keeps every joined Hub's grant current until cancelled: on each check-in, and at once when the token changes.
    func keepGrants(_ memberships: HubMemberships) async {
        while !Task.isCancelled {
            await renew(memberships.hubs)
            let seen = tokenChanges
            for _ in 0..<60 where !Task.isCancelled && tokenChanges == seen { try? await Task.sleep(for: .seconds(1)) }
        }
    }

    /// What one Hub needs, from what the phone registered for it, whether it still has that Hub's call key,
    /// and what the Hub last said it keeps.
    static func step(token: Data?, environment: PushAPNsEnvironment, record: CallPushRecord?, status: LinkStatus?,
                     hasKey: Bool, now: Date) -> Step {
        guard let status, status.ringsThroughPush else { return .none }
        guard let token else { return status.callPushExpiresAt == nil ? .none : .stop }
        guard let record, record.token == Data(SHA256.hash(data: token)), record.environment == environment,
              now.timeIntervalSince(record.registeredAt) < registrationAge else { return .register }
        // A grant went moments ago: the Hub's status may not show it yet, or the Hub refused it. Wait a while.
        if let granted = record.grantedAt, now.timeIntervalSince(granted) < grantPause { return .none }
        guard let expires = status.callPushExpiresAt else {
            // The Hub keeps none, as after Push said it no longer rings the token: register afresh, though not
            // again within an hour of the last registration.
            return now.timeIntervalSince(record.registeredAt) < registrationPause ? .grant : .register
        }
        // Without its key a push from the Hub could not say who calls: give the Hub a new one.
        guard hasKey else { return .grant }
        return expires.timeIntervalSince(now) < LinkCallPush.renewal ? .grant : .none
    }

    /// How long after sending a grant the phone sends none to that Hub, whatever its status says.
    static let grantPause: TimeInterval = 15 * 60
    /// How long a registration is used again for a Hub that dropped its grant, before registering anew.
    static let registrationPause: TimeInterval = 60 * 60

    func renew(_ pairings: [HubPairing], now: Date = Date()) async {
        // Keys of Hubs whose folders are gone, as the phone left them, go too.
        let joined = Set((pairings.compactMap { $0.hub?.key } + hubs().map(\.key)).map { PushCallPayload.hubHash(for: $0.x963) })
        for hub in keys.hubs where !joined.contains(hub) { keys.remove(for: hub) }
        for pairing in pairings { await renew(pairing, now: now) }
    }

    private func renew(_ pairing: HubPairing, now: Date) async {
        let folder = pairing.directory
        if let after = retryAfter[folder], after > now { return }
        guard let hub = pairing.hub else { return }
        let hash = PushCallPayload.hubHash(for: hub.key.x963)
        var record = CallPushRecord.load(from: folder)
        let step = Self.step(token: token, environment: environment, record: record, status: pairing.status,
                             hasKey: keys.key(for: hash) != nil, now: now)
        guard step != .none else { return }
        do {
            if step == .stop {
                _ = try await pairing.request(.callPush(LinkCallPush(grant: nil, callKey: nil)))
                CallPushRecord.remove(from: folder)
            } else {
                guard let token else { return }
                if step == .register || record == nil {
                    let registered = try await register(token, for: pairing, now: now)
                    registered.save(to: folder)
                    record = registered
                }
                guard var granted = record else { return }
                let key: Data
                if let kept = keys.key(for: hash) {
                    key = kept
                } else {
                    key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    // A key the phone could not keep would leave it unable to read who calls: send nothing.
                    try keys.save(key, for: hash)
                }
                let expires = now.addingTimeInterval(LinkCallPush.grantLifetime)
                let grant = try pairing.callGrant(sealed: granted.sealed, expiresAt: expires)
                granted.grantedAt = now
                granted.grantExpiresAt = expires
                granted.save(to: folder)
                _ = try await pairing.request(.callPush(LinkCallPush(grant: grant, callKey: key)))
                Self.log.notice("A Hub may ring this phone through Noodle Push for the next 14 days")
            }
            retryAfter[folder] = nil
            // The Hub's status says what it keeps now, so the next check does not send it again.
            await pairing.refresh(quietly: true)
        } catch {
            retryAfter[folder] = now.addingTimeInterval(Self.retryDelay)
            Self.log.error("Could not let a Hub ring this phone through Noodle Push: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Registers the token with Push, signed with the key this phone paired with the Hub, for a token sealed
    /// to that key alone.
    private func register(_ token: Data, for pairing: HubPairing, now: Date) async throws -> CallPushRecord {
        let registration = try pairing.pushRegistration(token: token, environment: environment, now: now)
        let (status, body) = try await post(LinkCallPush.service.appendingPathComponent("v1/register"), try JSONEncoder().encode(registration))
        guard status == 200, let registered = try? JSONDecoder().decode(PushRegistered.self, from: body) else {
            throw LinkError("Noodle Push did not register this phone (HTTP \(status)).")
        }
        return CallPushRecord(sealed: registered.sealed, registeredAt: now, token: Data(SHA256.hash(data: token)), environment: environment)
    }

    nonisolated static func postToPush(_ url: URL, _ body: Data) async throws -> (Int, Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    // MARK: PushKit

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        token = credentials.token
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        token = nil
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
                      completion: @escaping () -> Void) {
        guard type == .voIP else { return completion() }
        receive(payload.dictionaryPayload, completion: completion)
    }

    /// From iOS 26.4, which says when a push need not ring: the app is in front or already on a call, or the
    /// push came late. The Hub's own ring reaches an app in front, and a late call has stopped ringing.
    @available(iOS 26.4, *)
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingVoIPPushWith payload: PKPushPayload,
                      metadata: PKVoIPPushMetadata, withCompletionHandler completion: @escaping () -> Void) {
        guard metadata.mustReport else { return completion() }
        receive(payload.dictionaryPayload, completion: completion)
    }

    /// What a push's JSON asks for, read without any networking, as the call screen must hear of it first.
    /// The push names its Hub by its key's hash: a Hub the phone is not in, or a caller that does not open
    /// with that Hub's key, is refused.
    static func answer(to dictionary: [AnyHashable: Any], hubs: [PushedHub], keys: any CallKeys, now: Date) -> Answer {
        guard JSONSerialization.isValidJSONObject(dictionary), let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let payload = try? JSONDecoder().decode(PushCallPayload.self, from: data) else { return .refuse(UUID()) }
        guard let hub = hubs.first(where: { PushCallPayload.hubHash(for: $0.key.x963) == payload.hub }),
              let key = keys.key(for: payload.hub),
              let caller = LinkCallPushCaller.open(payload.blob, callID: payload.callID, with: key) else { return .refuse(payload.callID) }
        // The earlier of Push's end of the ring and the Hub's own, sealed with the caller.
        let ends = min(payload.expiresAt, caller.expiresAt ?? payload.expiresAt)
        let secondsLeft = TimeInterval(ends) - now.timeIntervalSince1970
        guard secondsLeft > 0 else { return .refuse(payload.callID) }
        return .ring(PushedCall(id: payload.callID, caller: caller, hub: hub, secondsLeft: min(secondsLeft, 300)))
    }

    private func receive(_ dictionary: [AnyHashable: Any], completion: @escaping () -> Void) {
        let done = PushCompletion(completion)
        switch Self.answer(to: dictionary, hubs: hubs(), keys: keys, now: Date()) {
        case .refuse(let id):
            Self.log.notice("Ended a call pushed from a Hub this phone could not read or is not in")
            screen.reportPushed(id, name: "Noodle", for: nil) { _ in done.run() }
        case .ring(let call):
            // Already ringing, as when the app heard the call from its Hub first: iOS still hears of the push.
            guard !screen.isShowing(call.id), sessions[call.id] == nil else {
                return screen.reportPushed(call.id, name: call.caller.botName, for: nil) { _ in done.run() }
            }
            let session = PushedCallSession(call)
            sessions[call.id] = session
            screen.reportPushed(call.id, name: call.caller.botName, for: session.line) { [weak self] rings in
                done.run()
                if rings { session.start { self?.sessions[call.id] = nil } } else { self?.sessions[call.id] = nil }
            }
        }
    }

    /// What happens to calls rung through Push, without tokens, keys or who called. Read in the Mac's Console.
    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NoodleMobile", category: "Calls")
}

/// PushKit's completion handler, which may run on any thread, carried into the call screen's.
private final class PushCompletion: @unchecked Sendable {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// A call a push woke the app for. It rings on the call screen while the app follows the Hub that placed it,
/// to hear if it stops ringing; answering and declining go to that Hub, as for a call that rang in the app.
@MainActor final class PushedCallSession {
    let call: PushedCall
    let line = PhoneCallLine()
    private let pairing: HubPairing
    private(set) lazy var calls = PhoneCalls(open: { [pairing, call] start in
        try await Self.connect(pairing, start, call)
    }, decline: { [pairing] id in
        _ = try await pairing.request(.declineCall(id: id))
    }, system: line)
    private var following: Task<Void, Never>?

    /// How long answering waits to reach the Hub before the call fails.
    static let connectTimeout: TimeInterval = 6

    init(_ call: PushedCall) {
        self.call = call
        pairing = HubPairing(directory: call.hub.folder, deviceName: UIDevice.current.name)
    }

    /// Rings until answered and hung up, declined, stopped on the Hub or out of time; then `finished` runs.
    func start(finished: @escaping @MainActor () -> Void) {
        calls.ring(LinkIncomingCall(id: call.id, botID: call.caller.botID, conversationID: call.caller.conversationID, reason: "",
                                    secondsLeft: call.secondsLeft), name: call.caller.botName)
        following = Task { [weak self] in
            await self?.follow()
            finished()
        }
    }

    private var isOn: Bool { !calls.ringing.isEmpty || calls.call != nil }

    /// Hears from the Hub when the call stops ringing, as when another device answered it, until the call is over.
    private func follow() async {
        let listening = Task { await listen() }
        while isOn { try? await Task.sleep(for: .seconds(1)) }
        listening.cancel()
    }

    private func listen() async {
        while isOn, !Task.isCancelled {
            if let events = try? await pairing.subscribe() {
                do {
                    for try await event in events {
                        if case .callStopped(let id) = event { calls.stopRinging(id) }
                    }
                } catch {}
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Reaches the Hub to answer, giving up after a few seconds; a call that cannot reach it is left as
    /// missed on the phone, saying why.
    private static func connect(_ pairing: HubPairing, _ start: LinkCallStart, _ call: PushedCall) async throws -> any CallChannel {
        do {
            return try await withTimeout(connectTimeout) { try await pairing.channel(.startCall(start)) }
        } catch {
            let content = UNMutableNotificationContent()
            content.title = "Missed call from \(call.caller.botName)"
            content.body = "Couldn’t reach \(call.hub.name)."
            content.sound = .default
            content.userInfo = [LinkPush.topicField: PushTopic.topic(for: call.hub.folder),
                                LinkPush.conversationField: call.caller.conversationID.uuidString]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "missed-\(call.id)", content: content,
                                                                                   trigger: nil))
            CallPushes.log.error("Could not reach the Hub to answer a call: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// The channel, or a failure once `seconds` pass first; a channel that opens later is closed.
    private static func withTimeout(_ seconds: TimeInterval,
                                    _ open: @escaping @MainActor @Sendable () async throws -> any CallChannel) async throws -> any CallChannel {
        let race = ChannelRace()
        return try await withCheckedThrowingContinuation { continuation in
            race.continuation = continuation
            let opening = Task { @MainActor in
                do { race.finish(.success(try await open())) } catch { race.finish(.failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if race.finish(.failure(LinkError("The Hub could not be reached.", isUnreachable: true))) { opening.cancel() }
            }
        }
    }
}

/// The first of opening a channel and a timeout, once; a channel that loses is closed.
@MainActor private final class ChannelRace {
    var continuation: CheckedContinuation<any CallChannel, Error>?

    @discardableResult func finish(_ result: Result<any CallChannel, Error>) -> Bool {
        guard let continuation else {
            if case .success(let channel) = result { channel.cancel() }
            return false
        }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}
