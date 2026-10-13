import XCTest
@testable import NoodleCore

final class BotWidgetsTests: XCTestCase {
    private func bot(_ name: String, working: Bool = false, finishedAt: Date? = nil) -> WidgetBot {
        WidgetBot(id: UUID(), conversationID: UUID(), name: name, isWorking: working, finishedAt: finishedAt)
    }

    func testLauncherPutsPinnedBotsFirstInPinOrder() {
        let alfred = bot("Alfred"), blake = bot("Blake"), cleo = bot("Cleo"), dora = bot("Dora")
        let ordered = WidgetBots.launcher([alfred, blake, cleo, dora],
                                          pinnedConversationIDs: [cleo.conversationID, UUID(), blake.conversationID])
        XCTAssertEqual(ordered.map(\.name), ["Cleo", "Blake", "Alfred", "Dora"])
    }

    func testRecentShowsWorkingThenLatestFinishedAndSkipsIdle() {
        let now = Date()
        let bots = [bot("Idle"), bot("Earlier", finishedAt: now.addingTimeInterval(-600)),
                    bot("Working", working: true), bot("Latest", finishedAt: now.addingTimeInterval(-60))]
        XCTAssertEqual(WidgetBots.recent(bots).map(\.name), ["Working", "Latest", "Earlier"])
    }

    func testSettleMarksABotThatStoppedWorkingAsFinished() {
        let now = Date(), earlier = now.addingTimeInterval(-3_600)
        var working = bot("Alfred", working: true)
        var stillIdle = bot("Blake", finishedAt: earlier)
        let previous = [working, stillIdle]
        working.isWorking = false
        stillIdle.finishedAt = nil
        let settled = WidgetBots.settle([working, stillIdle], previous: previous, now: now)
        XCTAssertEqual(settled[0].finishedAt, now)
        XCTAssertEqual(settled[1].finishedAt, earlier, "A finish time seen once is kept")
    }

    func testStatusLineFallsBackToTheBotsLatestReply() {
        let agent = UUID(), conversation = UUID()
        let messages = [
            ChatMessage(conversationID: conversation, author: .agent(agent), body: "Earlier", delivery: .saved),
            ChatMessage(conversationID: conversation, author: .agent(agent), body: "**Booked** the table", delivery: .saved),
            ChatMessage(conversationID: conversation, author: .user, body: "Thanks", delivery: .saved),
        ]
        let plain = { (body: String) in body.replacingOccurrences(of: "**", with: "") }
        XCTAssertEqual(WidgetBots.statusLine(status: nil, messages: messages, agentID: agent, preview: plain),
                       "Booked the table")
        XCTAssertEqual(WidgetBots.statusLine(status: "Planning", messages: messages, agentID: agent, preview: plain),
                       "Planning", "A status the bot set wins")
        XCTAssertNil(WidgetBots.statusLine(status: nil, messages: [messages[2]], agentID: agent, preview: plain))
    }

    func testLinkOpensTheBotsConversation() {
        let alfred = bot("Alfred")
        let link = WidgetBots.link(to: alfred, scheme: "noodle-dev")
        XCTAssertEqual(link.scheme, "noodle-dev")
        XCTAssertEqual(WidgetBots.conversationID(fromLink: link), alfred.conversationID)
        XCTAssertNil(WidgetBots.conversationID(fromLink: URL(string: "noodle://shared")!))
    }

    func testShelfSavesOnlyChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-widgets-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = BotWidgetShelf(rootURL: root)
        let bots = [bot("Alfred", finishedAt: Date(timeIntervalSince1970: 1_000))]
        XCTAssertEqual(shelf.load(), [])
        XCTAssertTrue(try shelf.save(bots))
        XCTAssertFalse(try shelf.save(bots))
        XCTAssertEqual(shelf.load(), bots)
    }
}
