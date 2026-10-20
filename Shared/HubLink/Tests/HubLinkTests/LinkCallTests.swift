import Foundation
@testable import HubLink
import XCTest

final class LinkCallTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testACallStartsWithItsConversationAndItsEventsTravelTheChannel() throws {
        let start = LinkCallStart(conversationID: UUID())
        guard case .success(.startCall(let decoded)) = LinkProtocol.decode(try LinkProtocol.encode(.startCall(start))) else {
            return XCTFail("The request did not survive the link")
        }
        XCTAssertEqual(decoded, start)

        let events: [LinkCallEvent] = [.started, .line(LinkCallLine(speaker: .you, text: "Hi", at: date)),
                                       .line(LinkCallLine(speaker: .bot, text: "Hello", at: nil)), .ended(nil), .ended("The bot stopped.")]
        for event in events { XCTAssertEqual(LinkCallEvent(event.encoded), event) }
        XCTAssertNil(LinkCallEvent(Data("not json".utf8)))
    }

    func testCallsTravelOnMessagesAndBotsAndOlderPayloadsStillDecode() throws {
        var message = LinkMessage(id: UUID(), conversationID: UUID(), author: .you, body: "Voice call", createdAt: date, delivered: true)
        message.call = LinkCallRecord(botID: UUID(), endedAt: date, lines: [LinkCallLine(speaker: .bot, text: "Done.", at: date)])
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(LinkMessage.self, from: encoder.encode(message)), message)

        var plain = message
        plain.call = nil
        XCTAssertNil(try decoder.decode(LinkMessage.self, from: encoder.encode(plain)).call)

        var draft = LinkBotDraft(name: "Yuki", provider: "codex")
        XCTAssertNil(try decoder.decode(LinkBotDraft.self, from: encoder.encode(draft)).voice)
        draft.voice = "maple"
        XCTAssertEqual(try decoder.decode(LinkBotDraft.self, from: encoder.encode(draft)).voice, "maple")

        var bot = LinkBot(id: UUID(), conversationID: UUID(), draft: draft, createdAt: date)
        XCTAssertFalse(try decoder.decode(LinkBot.self, from: encoder.encode(bot)).canCall)
        bot.canCall = true
        XCTAssertTrue(try decoder.decode(LinkBot.self, from: encoder.encode(bot)).canCall)

        var harness = LinkHarness(provider: "codex", providerName: "Codex", profileName: nil)
        XCTAssertEqual(try decoder.decode(LinkHarness.self, from: encoder.encode(harness)).voices, [])
        harness.voices = [LinkCallVoice(id: "maple", name: "Maple", presentation: .feminine)]
        XCTAssertEqual(try decoder.decode(LinkHarness.self, from: encoder.encode(harness)).voices, harness.voices)
    }

    func testBotsCallsRingOverTheLinkAndOlderPayloadsStillDecode() throws {
        let call = LinkIncomingCall(id: UUID(), botID: UUID(), conversationID: UUID(), reason: "The build is broken", expiresAt: date)
        for event in [LinkEvent.callRinging(call), .callStopped(id: call.id)] {
            XCTAssertEqual(LinkProtocol.decodeEvent(LinkProtocol.encode(event)), event)
        }
        guard case .success(.declineCall(let declined)) = LinkProtocol.decode(try LinkProtocol.encode(.declineCall(id: call.id))) else {
            return XCTFail("The decline did not survive the link")
        }
        XCTAssertEqual(declined, call.id)
        let answering = LinkCallStart(conversationID: call.conversationID, answering: call.id)
        guard case .success(.startCall(let start)) = LinkProtocol.decode(try LinkProtocol.encode(.startCall(answering))) else {
            return XCTFail("The answer did not survive the link")
        }
        XCTAssertEqual(start, answering)

        // What devices and Hubs from before calls could ring send.
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(LinkCallStart.self, from: Data(#"{"conversationID":"\#(call.conversationID)"}"#.utf8)).answering)
        XCTAssertFalse(try decoder.decode(LinkStatus.self, from: Data(#"{"hubName":"Mac mini"}"#.utf8)).ringsCalls)
        let bot = call.botID.uuidString
        XCTAssertNil(try decoder.decode(LinkCallRecord.self, from: Data(#"{"botID":"\#(bot)","lines":[]}"#.utf8)).unanswered)
        let declinedCard = try decoder.decode(LinkCallRecord.self, from: Data(#"{"botID":"\#(bot)","unanswered":"declined","reason":"Why"}"#.utf8))
        XCTAssertEqual(declinedCard.unanswered, .declined)
        XCTAssertEqual(declinedCard.reason, "Why")
        XCTAssertEqual(try decoder.decode(LinkCallRecord.self, from: Data(#"{"botID":"\#(bot)","unanswered":"busy"}"#.utf8)).unanswered, .missed)
    }
}
