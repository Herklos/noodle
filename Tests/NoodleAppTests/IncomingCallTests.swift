import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class IncomingCallTests: XCTestCase {
    private let date = Date()

    private func wait(_ what: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<500 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate(), what)
    }

    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        f.store.makeCallPeer = { VoiceCallPeerFake() }
        return f
    }

    /// What Noodle left the bot to read on its next wake.
    private func wakeNotes(_ f: StoreFixture, _ agent: AgentRecord) -> String {
        let file = f.repository.storage(for: agent.id).package.appendingPathComponent("wakes.json")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    private func cards(_ f: StoreFixture) -> [VoiceCallRecord] {
        f.store.messages(for: f.directA).compactMap(\.call)
    }

    func testABotsCallRingsAndAnsweringCallsItToldWhyItCalled() async throws {
        let f = try fixture()
        // Noodle rings a bot's call as soon as Messenger accepts it.
        XCTAssertNotNil(f.store.messenger.onCallRequested)
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "The release build is failing", now: date)
        f.store.ringCall(of: f.a.id, now: date)
        f.store.ringCall(of: f.a.id, now: date)
        XCTAssertEqual(f.store.ringingCalls, [request])
        XCTAssertTrue(f.runtime.factory.processes.isEmpty, "Nothing connects to the bot before the call is answered")

        f.store.answerCall(request.id, media: VoiceCallMediaFake())
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        try await wait("the bot's voice was called") { f.runtime.factory.processes.first?.voiceCallRequests.count == 1 }
        XCTAssertEqual(f.store.voiceCalls.call?.conversationID, f.directA.id)
        XCTAssertEqual(f.runtime.factory.processes.first?.voiceCallRequests.first?.answeredCallReason, "The release build is failing")
        XCTAssertNil(f.repository.pendingCall(agentID: f.a.id))
        XCTAssertTrue(cards(f).allSatisfy { $0.unanswered == nil })
        f.store.voiceCalls.hangUp()
    }

    func testADeclinedCallLeavesAnUnreadCardAndTellsTheBot() async throws {
        let f = try fixture()
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "Need a decision on the release", now: date)
        f.store.ringCall(of: f.a.id, now: date)
        f.store.declineCall(request.id)
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertNil(f.store.voiceCalls.call)
        XCTAssertEqual(cards(f).last?.unanswered, .declined)
        XCTAssertEqual(cards(f).last?.reason, "Need a decision on the release")
        XCTAssertTrue(f.store.unreadConversationIDs.contains(f.directA.id))
        XCTAssertNil(f.repository.pendingCall(agentID: f.a.id))
        await f.runtime.runtime.settleWakes()
        XCTAssertTrue(wakeNotes(f, f.a).contains("declined your call about: Need a decision on the release"))
        // Answering once it is over does nothing.
        f.store.answerCall(request.id, media: VoiceCallMediaFake())
        XCTAssertNil(f.store.voiceCalls.call)
    }

    func testACallNobodyAnswersIsMissedOnce() async throws {
        let f = try fixture()
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "The disk is almost full", now: date)
        f.store.ringCall(of: f.a.id, now: date)
        f.store.expireCalls(at: request.expiresAt.addingTimeInterval(-1))
        XCTAssertEqual(f.store.ringingCalls, [request])
        f.store.expireCalls(at: request.expiresAt)
        f.store.expireCalls(at: request.expiresAt.addingTimeInterval(1))
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertEqual(cards(f).map(\.unanswered), [.missed])
        await f.runtime.runtime.settleWakes()
        XCTAssertTrue(wakeNotes(f, f.a).contains("did not answer your call about: The disk is almost full"))
    }

    /// A call that rang while Noodle quit is missed when it is found too late.
    func testACallFoundAfterItExpiredIsMissedWithoutRinging() throws {
        let f = try fixture()
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "The disk is almost full", now: date)
        f.store.ringCall(of: f.a.id, now: request.expiresAt.addingTimeInterval(60))
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertEqual(cards(f).map(\.unanswered), [.missed])
        XCTAssertNil(f.repository.pendingCall(agentID: f.a.id))
    }

    /// Nobody on a call is rung: the call is left as missed. Answering never hangs up a call in progress.
    func testNoCallRingsDuringACallAndAnsweringNeverEndsOne() async throws {
        let f = try fixture()
        f.store.startVoiceCall(in: f.directB, media: VoiceCallMediaFake())
        try await wait("the call with Grace started") { f.store.voiceCalls.call != nil }
        _ = try f.repository.requestCall(agentID: f.a.id, reason: "The build is broken", now: date)
        f.store.ringCall(of: f.a.id, now: date)
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertEqual(cards(f).map(\.unanswered), [.missed])
        XCTAssertNil(f.repository.pendingCall(agentID: f.a.id))
        f.store.voiceCalls.hangUp()

        let later = date.addingTimeInterval(AgentCallLimits.cooldown + 60)
        let ringing = try f.repository.requestCall(agentID: f.a.id, reason: "Still broken", now: later)
        f.store.ringCall(of: f.a.id, now: later)
        XCTAssertEqual(f.store.ringingCalls, [ringing])
        f.store.startVoiceCall(in: f.directB, media: VoiceCallMediaFake())
        try await wait("the call with Grace started") { f.store.voiceCalls.call != nil }
        f.store.answerCall(ringing.id, media: VoiceCallMediaFake())
        XCTAssertEqual(f.store.voiceCalls.call?.conversationID, f.directB.id)
        XCTAssertEqual(f.store.ringingCalls, [ringing], "It rings on until it is missed")
        f.store.voiceCalls.hangUp()
    }

    /// A bot archived while its call rings has nobody left to answer it: the call ends without a card or a note.
    func testACallOfABotArchivedWhileRingingEndsQuietly() async throws {
        let f = try fixture()
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "The build is broken", now: date)
        f.store.ringCall(of: f.a.id, now: date)
        XCTAssertEqual(f.store.ringingCalls, [request])
        XCTAssertTrue(f.store.setArchived(true, agentID: f.a.id))
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertNil(f.repository.pendingCall(agentID: f.a.id))
        f.store.expireCalls(at: request.expiresAt)
        await f.runtime.runtime.settleWakes()
        XCTAssertTrue(try f.repository.loadMessages(conversationID: f.directA.id).allSatisfy { $0.call == nil })
        XCTAssertFalse(wakeNotes(f, f.a).contains("your call"))
    }
}
