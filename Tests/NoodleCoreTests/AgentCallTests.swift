import XCTest
@testable import NoodleCore

final class AgentCallTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func messenger(_ agent: AgentRecord, _ arguments: String...) -> MessengerCommandResult {
        let command = repository.directory(for: agent).appendingPathComponent(".agents/skills/messenger/messenger")
        return MessengerCLI.runDirect(arguments: [command.path] + arguments)
    }

    private func refusal(_ body: () throws -> AgentCallRequest) -> String {
        do { _ = try body() } catch { return error.localizedDescription }
        XCTFail("The call was placed")
        return ""
    }

    func testABotWhoseHarnessTakesCallsCallsItsPersonFromItsOwnConversation() throws {
        let made = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue)
        let result = messenger(made.agent, "--call", "--reason", "The release build is failing")
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request = try decoder.decode(AgentCallRequest.self, from: Data(result.standardOutput.utf8))
        XCTAssertEqual(request.agentID, made.agent.id)
        XCTAssertEqual(request.conversationID, made.conversation.id)
        XCTAssertEqual(request.reason, "The release build is failing")
        XCTAssertEqual(request.expiresAt.timeIntervalSince(request.requestedAt), AgentCallLimits.ringing)
        XCTAssertEqual(repository.pendingCall(agentID: made.agent.id), request)
        // Kept beside agent.json, where the bot cannot change it.
        let workspace = repository.directory(for: made.agent).standardizedFileURL.path
        let stored = repository.storage(for: made.agent.id).package.appendingPathComponent("calls.json").standardizedFileURL.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored))
        XCTAssertFalse(stored.hasPrefix(workspace + "/"))
    }

    func testOnlyBotsWhoseHarnessTakesCallsCanCallAndOnlyWithAShortReason() throws {
        let claude = try repository.createAgent(named: "Clara", harnessIdentifier: HarnessProvider.claudeCode.rawValue).agent
        let refused = messenger(claude, "--call", "--reason", "Hello")
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertTrue(refused.standardError.contains("cannot take voice calls"), refused.standardError)
        XCTAssertNil(repository.pendingCall(agentID: claude.id))

        let codex = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue).agent
        XCTAssertNotEqual(messenger(codex, "--call").exitCode, 0)
        XCTAssertNotEqual(messenger(codex, "--call", "--reason", "  ").exitCode, 0)
        XCTAssertNotEqual(messenger(codex, "--call", "--reason", String(repeating: "a", count: AgentCallLimits.reasonLength + 1)).exitCode, 0)
        XCTAssertNil(repository.pendingCall(agentID: codex.id))
        let request = try repository.requestCall(agentID: codex.id, reason: "Two\nlines", now: date)
        XCTAssertEqual(request.reason, "Two lines")
    }

    func testOneCallRingsAtATimeThenACooldownAndADailyLimitApply() throws {
        let bot = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue).agent
        let minute: TimeInterval = 60
        let first = try repository.requestCall(agentID: bot.id, reason: "One", now: date)
        XCTAssertTrue(refusal { try repository.requestCall(agentID: bot.id, reason: "Again", now: date.addingTimeInterval(10)) }
            .contains("still ringing"))
        XCTAssertEqual(try repository.endCall(agentID: bot.id, id: first.id), first)
        XCTAssertNil(try repository.endCall(agentID: bot.id, id: first.id))
        XCTAssertTrue(refusal { try repository.requestCall(agentID: bot.id, reason: "Again", now: date.addingTimeInterval(10 * minute)) }
            .contains("less than 30 minutes ago"))

        let second = try repository.requestCall(agentID: bot.id, reason: "Two", now: date.addingTimeInterval(31 * minute))
        _ = try repository.endCall(agentID: bot.id, id: second.id)
        let third = try repository.requestCall(agentID: bot.id, reason: "Three", now: date.addingTimeInterval(62 * minute))
        _ = try repository.endCall(agentID: bot.id, id: third.id)
        XCTAssertTrue(refusal { try repository.requestCall(agentID: bot.id, reason: "Four", now: date.addingTimeInterval(93 * minute)) }
            .contains("3 times in the last 24 hours"))
        // The first call leaves the last 24 hours.
        XCTAssertNoThrow(try repository.requestCall(agentID: bot.id, reason: "Next day", now: date.addingTimeInterval(24 * 60 * minute + minute)))
    }

    func testACallThatRangWhileNobodyEndedItStopsBlockingTheNextOne() throws {
        let bot = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue).agent
        let stale = try repository.requestCall(agentID: bot.id, reason: "One", now: date)
        let next = try repository.requestCall(agentID: bot.id, reason: "Two", now: date.addingTimeInterval(31 * 60))
        XCTAssertNotEqual(next.id, stale.id)
        XCTAssertEqual(repository.pendingCall(agentID: bot.id), next)
    }

    func testAnUnansweredCallLeavesACardFromTheBotThatNeverReachesItsInbox() throws {
        let made = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue)
        let request = try repository.requestCall(agentID: made.agent.id, reason: "The build is broken", now: date)
        let card = try repository.recordUnansweredCall(request, .missed, at: request.expiresAt)
        XCTAssertEqual(card.author, .agent(made.agent.id))
        XCTAssertEqual(card.body, "Missed call")
        XCTAssertEqual(card.call, VoiceCallRecord(agentID: made.agent.id, endedAt: request.expiresAt, unanswered: .missed,
                                                  reason: "The build is broken"))
        XCTAssertEqual(try repository.loadMessages(conversationID: made.conversation.id).last, card)
        XCTAssertEqual(try repository.recordUnansweredCall(request, .declined).body, "Declined call")
        XCTAssertTrue(try repository.latestMessages(for: made.agent.id).isEmpty)

        // Cards saved before calls could be missed still read.
        let older = try JSONDecoder().decode(VoiceCallRecord.self, from: Data(#"{"agentID":"\#(made.agent.id)","lines":[]}"#.utf8))
        XCTAssertNil(older.unanswered)
        XCTAssertNil(older.reason)
    }

    func testTheBotLearnsWhyItsCallWentUnansweredAndWhatToDoInstead() {
        let conversation = UUID()
        let missed = AgentCallDocumentation.unansweredNote(.missed, personName: "Petko", reason: "The build is broken", conversationID: conversation)
        XCTAssertTrue(missed.contains("Petko did not answer your call about: The build is broken"))
        XCTAssertTrue(missed.contains(conversation.uuidString.lowercased()))
        XCTAssertTrue(missed.contains("do not call again"))
        XCTAssertTrue(AgentCallDocumentation.unansweredNote(.declined, personName: "Petko", reason: "x", conversationID: conversation)
            .contains("Petko declined your call"))

        let answered = VoiceCallDocumentation.startInstructions(conversationID: conversation, personName: "Petko",
                                                                answeredCallReason: "The build is broken")
        XCTAssertTrue(answered.contains("Petko answered the voice call you placed"))
        XCTAssertTrue(answered.contains("You called about: The build is broken"))
        XCTAssertTrue(VoiceCallDocumentation.startInstructions(conversationID: conversation, personName: "Petko")
            .contains("Petko started a voice call with you"))
        XCTAssertTrue(MessengerDocumentation.skillInstructions.contains("messenger --call --reason <text>"))
    }
}
