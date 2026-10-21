import APNS
import APNSCore
import Crypto
import Foundation
import NIOPosix
import PushWire

/// One VoIP push, ready for APNs.
public struct VoIPPush: Sendable, Equatable {
    public var token: Data
    public var environment: PushAPNsEnvironment
    public var payload: PushCallPayload

    public init(token: Data, environment: PushAPNsEnvironment, payload: PushCallPayload) {
        self.token = token
        self.environment = environment
        self.payload = payload
    }
}

/// What APNs made of a push.
public enum VoIPDelivery: Sendable, Equatable {
    case sent
    /// APNs answered with an error status and, usually, a reason such as `Unregistered`.
    case refused(status: Int, reason: String?)
    /// No answer: the connection failed or timed out.
    case unreachable
}

public protocol VoIPSending: Sendable {
    func send(_ push: VoIPPush) async -> VoIPDelivery
}

/// Sends through APNSwift over HTTP/2 with the team's .p8 key: one client per APNs host, since the phone's
/// build picks the host. Each client opens its connection on the first push and signs a fresh JWT as the
/// old one ages. AsyncHTTPClient closes an idle connection after a minute, so the first ring after a
/// quiet spell pays one TLS handshake to Apple, about 0.2 s; the container itself stays warm through
/// the Worker's cron ping.
public struct APNsVoIPSender: VoIPSending {
    public let topic: String
    let clients: [PushAPNsEnvironment: any APNSClientProtocol]
    let timeout: Duration

    public init(topic: String, clients: [PushAPNsEnvironment: any APNSClientProtocol], timeout: Duration) {
        self.topic = topic
        self.clients = clients
        self.timeout = timeout
    }

    public init(configuration: PushConfiguration) {
        var clients: [PushAPNsEnvironment: any APNSClientProtocol] = [:]
        for environment in PushAPNsEnvironment.allCases {
            clients[environment] = APNSClient(
                configuration: APNSClientConfiguration(
                    authenticationMethod: .jwt(privateKey: configuration.apnsKey, keyIdentifier: configuration.apnsKeyID,
                                               teamIdentifier: configuration.teamID),
                    environment: environment == .production ? .production : .development),
                eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), responseDecoder: JSONDecoder(), requestEncoder: JSONEncoder())
        }
        self.init(topic: configuration.topic, clients: clients, timeout: configuration.limits.apnsTimeout)
    }

    /// The request for `push`. Push fixes everything here: the topic, the VoIP push type, priority 10, and
    /// expiration 0 so APNs never delivers a ring late instead of storing it.
    public func request(for push: VoIPPush) -> APNSRequest<APNSVoIPNotification<PushCallPayload>> {
        let notification = APNSVoIPNotification(expiration: .immediately, priority: .immediately, topic: topic,
                                                payload: push.payload)
        return APNSRequest(message: notification, deviceToken: push.token.map { hex($0) }.joined(), pushType: .voip,
                           expiration: notification.expiration, priority: notification.priority,
                           apnsID: notification.apnsID, topic: notification.topic, collapseID: nil)
    }

    public func send(_ push: VoIPPush) async -> VoIPDelivery {
        guard let client = clients[push.environment] else { return .unreachable }
        let request = request(for: push)
        let timeout = timeout
        do {
            return try await withThrowingTaskGroup(of: VoIPDelivery?.self) { group in
                group.addTask {
                    _ = try await client.send(request)
                    return .sent
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next().flatMap { $0 } ?? .unreachable
            }
        } catch let error as APNSError {
            return .refused(status: error.responseStatus, reason: error.reason?.reason)
        } catch {
            return .unreachable
        }
    }

    public func shutdown() async {
        for client in clients.values { try? await client.shutdown() }
    }
}

private func hex(_ byte: UInt8) -> String {
    let digits = Array("0123456789abcdef")
    return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
}
