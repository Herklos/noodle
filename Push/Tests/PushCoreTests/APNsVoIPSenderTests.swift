import APNSCore
import Foundation
@testable import PushCore
import PushWire
import XCTest

/// Stands in for APNSwift's HTTP/2 client: keeps each request's headers, token and JSON body.
final class MockAPNsClient: APNSClientProtocol, @unchecked Sendable {
    struct Sent {
        var headers: [String: String]
        var deviceToken: String
        var body: [String: Any]
    }

    enum Behaviour { case accept, fail(Error), hang }

    private let lock = NSLock()
    private var storage: [Sent] = []
    private let behaviour: Behaviour
    var sent: [Sent] { lock.withLock { storage } }

    init(_ behaviour: Behaviour = .accept) { self.behaviour = behaviour }

    func send(_ request: APNSRequest<some APNSMessage>) async throws -> APNSResponse {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.message)) as? [String: Any] ?? [:]
        lock.withLock { storage.append(Sent(headers: request.headers, deviceToken: request.deviceToken, body: body)) }
        switch behaviour {
        case .accept: return APNSResponse()
        case .fail(let error): throw error
        case .hang:
            try await Task.sleep(for: .seconds(3_600))
            return APNSResponse()
        }
    }

    func shutdown() async throws {}
}

final class APNsVoIPSenderTests: XCTestCase {
    private let push = VoIPPush(token: Data([0x0A, 0xFF, 0x00, 0x7B]), environment: .production,
                                payload: PushCallPayload(callID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
                                                         expiresAt: 1_800_000_045, blob: Data([1, 2, 3])))

    func testThePushIsAVoIPRingThatAPNsNeverStores() async throws {
        let production = MockAPNsClient(), sandbox = MockAPNsClient()
        let sender = APNsVoIPSender(topic: "com.pdparchitect.noodle.mobile.voip",
                                    clients: [.production: production, .sandbox: sandbox], timeout: .seconds(5))
        let delivery = await sender.send(push)
        XCTAssertEqual(delivery, .sent)
        XCTAssertTrue(sandbox.sent.isEmpty, "The sealed environment picks the host")
        let sent = try XCTUnwrap(production.sent.first)
        XCTAssertEqual(sent.headers, ["apns-push-type": "voip", "apns-topic": "com.pdparchitect.noodle.mobile.voip",
                                      "apns-priority": "10", "apns-expiration": "0"])
        XCTAssertEqual(sent.deviceToken, "0aff007b")
        XCTAssertEqual(sent.body["callID"] as? String, "6F9619FF-8B86-D011-B42D-00C04FC964FF")
        XCTAssertEqual(sent.body["exp"] as? Int, 1_800_000_045)
        XCTAssertEqual(sent.body["blob"] as? String, "AQID")
        XCTAssertEqual(Set(sent.body.keys), ["callID", "exp", "blob"], "Nothing readable rides along")

        var sandboxPush = push
        sandboxPush.environment = .sandbox
        _ = await sender.send(sandboxPush)
        XCTAssertEqual(sandbox.sent.count, 1)
    }

    func testAPNsRefusalsKeepTheirStatusAndReason() async throws {
        let unregistered = try JSONDecoder().decode(APNSErrorResponse.self, from: Data(#"{"reason":"Unregistered","timestamp":1800000000000}"#.utf8))
        let gone = APNsVoIPSender(topic: "t", clients: [.production: MockAPNsClient(.fail(APNSError(responseStatus: 410, apnsResponse: unregistered)))],
                                  timeout: .seconds(5))
        let goneDelivery = await gone.send(push)
        XCTAssertEqual(goneDelivery, .refused(status: 410, reason: "Unregistered"))

        let badToken = try JSONDecoder().decode(APNSErrorResponse.self, from: Data(#"{"reason":"BadDeviceToken"}"#.utf8))
        let bad = APNsVoIPSender(topic: "t", clients: [.production: MockAPNsClient(.fail(APNSError(responseStatus: 400, apnsResponse: badToken)))],
                                 timeout: .seconds(5))
        let badDelivery = await bad.send(push)
        XCTAssertEqual(badDelivery, .refused(status: 400, reason: "BadDeviceToken"))
        XCTAssertTrue(PushService.meansTokenGone(status: 400, reason: "BadDeviceToken"))
        XCTAssertFalse(PushService.meansTokenGone(status: 400, reason: "BadPriority"))

        struct Broken: Error {}
        let broken = APNsVoIPSender(topic: "t", clients: [.production: MockAPNsClient(.fail(Broken()))], timeout: .seconds(5))
        let brokenDelivery = await broken.send(push)
        XCTAssertEqual(brokenDelivery, .unreachable)
    }

    func testASilentAPNsCountsAsUnreachable() async {
        let sender = APNsVoIPSender(topic: "t", clients: [.production: MockAPNsClient(.hang)], timeout: .milliseconds(10))
        let delivery = await sender.send(push)
        XCTAssertEqual(delivery, .unreachable)
    }
}
