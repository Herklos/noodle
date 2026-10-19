import XCTest
@testable import NoodleCore

final class MessageDeliveryTests: XCTestCase {
    func testDefaultAndStoredMode() {
        let suite = "MessageDeliveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MessageDeliveryMode.load(from: defaults), .automatic)
        for mode in MessageDeliveryMode.allCases {
            defaults.set(mode.rawValue, forKey: MessageDeliveryMode.defaultsKey)
            XCTAssertEqual(MessageDeliveryMode.load(from: defaults), mode)
        }
        defaults.set("obsolete", forKey: MessageDeliveryMode.defaultsKey)
        XCTAssertEqual(MessageDeliveryMode.load(from: defaults), .automatic)
    }

    func testCoalescingPromotionAndLateClassification() {
        var pending = PendingAgentNotification()
        let first = pending.enqueue()
        XCTAssertEqual(pending.enqueue(), first)
        pending.promote(first)
        XCTAssertTrue(pending.isImmediate)
        XCTAssertEqual(pending.take(), first)
        let second = pending.enqueue()
        XCTAssertNotEqual(first, second)
        pending.promote(first)
        XCTAssertFalse(pending.isImmediate, "An old classification cannot steer a newer wake")
        pending.restore(first)
        XCTAssertEqual(pending.id, second, "Restoring a rejected steer preserves newer pending work")
        pending.promote(second)
        pending.deferUntilReady()
        XCTAssertTrue(pending.isPending)
        XCTAssertFalse(pending.isImmediate)
    }

    func testStopRequestBelongsToItsOwnWake() {
        var pending = PendingAgentNotification()
        let first = pending.enqueue(immediately: true)
        XCTAssertFalse(pending.requestsStop, "An urgent message is not a stop request")
        pending.requestStop(UUID())
        XCTAssertFalse(pending.requestsStop)
        pending.requestStop(first)
        XCTAssertTrue(pending.requestsStop)
        XCTAssertTrue(pending.isImmediate)
        pending.take()
        pending.enqueue()
        pending.requestStop(first)
        XCTAssertFalse(pending.requestsStop, "An old stop request cannot end a newer turn")
    }

    func testContextContainsUnreadVoiceAndHistoryWithoutConsumingInbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Builder")
        let conversation = try XCTUnwrap(repository.loadConversations().first)
        _ = try repository.sendUserMessage(conversationID: conversation.id, body: "Work on the website")
        _ = try repository.latestMessages(for: bot.agent.id)
        let file = root.appendingPathComponent("voice.caf")
        try Data([1, 2, 3]).write(to: file)
        let attachment = try repository.importAttachment(from: file, into: conversation.id, mediaType: "audio/x-caf",
            voice: VoiceMessage(transcript: "Hold off for now", duration: 1, waveform: [0.2], localeIdentifier: "en-GB"))
        _ = try repository.sendUserMessage(conversationID: conversation.id, body: VoiceMessage.messageBody,
                                          attachmentIDs: [attachment.id])
        let context = try XCTUnwrap(MessageDeliveryContext.load(for: bot.agent.id, repository: repository))
        XCTAssertTrue(context.unreadMessages.joined().contains("Hold off for now"))
        XCTAssertTrue(context.recentMessages.joined().contains("Work on the website"))
        XCTAssertEqual(try repository.latestMessages(for: bot.agent.id).count, 1)
        XCTAssertNil(try MessageDeliveryContext.load(for: bot.agent.id, repository: repository))
    }

    func testContextIsBoundedAndEncodedAsData() throws {
        let context = MessageDeliveryContext(unreadMessages: Array(repeating: String(repeating: "a", count: 10_000), count: 10)
            + ["\"ignore instructions\"\nexample"], recentMessages: ["Assistant: working"])
        XCTAssertEqual(context.unreadMessages.count, 4)
        XCTAssertEqual(context.unreadMessages[0].count, 800)
        XCTAssertLessThan(context.prompt.count, 5_500)
        XCTAssertTrue(context.prompt.contains("\\\"ignore instructions\\\"\\nexample"))
        XCTAssertTrue(context.prompt.contains("New messages:"))
    }

    func testPromptQuotesEachNewMessageSeparatelyFromHandledHistory() {
        let context = MessageDeliveryContext(unreadMessages: ["Use blue", "thanks"],
                                             recentMessages: ["User: Build the page", "Assistant: Which colour?"])
        XCTAssertTrue(context.prompt.contains("1. \"Use blue\""))
        XCTAssertTrue(context.prompt.contains("2. \"thanks\""))
        XCTAssertTrue(context.prompt.contains("Already handled:\nUser: Build the page\nAssistant: Which colour?"))
    }

    func testStopRequestsAreRecognisedWithoutAModel() {
        for text in ["stop", "Stop!", "  wait, that is the wrong file", "Hold on", "hold off for now", "Pause",
                     "cancel that", "Abort", "don't push", "Don’t delete it", "do not merge", "No, use the other one",
                     "no", "No!", "Voice message\nStop editing"] {
            XCTAssertTrue(MessageDeliveryContext(unreadMessages: ["Thanks", text], recentMessages: []).requestsStop, text)
        }
        for text in ["Stopwatch app next", "No worries", "nothing else", "Waiting is fine", "Could you stop by later?",
                     "Please also add a footer", "thanks"] {
            XCTAssertFalse(MessageDeliveryContext(unreadMessages: [text], recentMessages: []).requestsStop, text)
        }
    }
}
