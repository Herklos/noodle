import XCTest
@testable import NoodleCore

final class AgentWakeTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

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

    private func decode<Value: Decodable>(_ type: Value.Type, from result: MessengerCommandResult) throws -> Value {
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(result.standardOutput.utf8))
    }

    func testBotSchedulesListsAndCancelsItsOwnWakes() throws {
        let bot = try repository.createAgent(named: "Build Bot").agent
        let before = Date()
        let soon = try decode(AgentWake.self, from: messenger(bot, "--wake-in", "20m", "--note", "Check the build"))
        XCTAssertEqual(soon.note, "Check the build")
        XCTAssertEqual(soon.dueAt.timeIntervalSince(before), 1_200, accuracy: 5)
        let later = try decode(AgentWake.self, from: messenger(bot, "--wake-at", "2099-01-02T09:00:00Z", "--note", "Report back"))
        XCTAssertEqual(later.dueAt, ISO8601DateFormatter().date(from: "2099-01-02T09:00:00Z"))

        let listed = try decode(AgentWakeList.self, from: messenger(bot, "--list-wakes"))
        XCTAssertEqual(listed.pending.map(\.note), ["Check the build", "Report back"])
        XCTAssertTrue(listed.due.isEmpty)
        XCTAssertEqual(repository.nextWakeDate(agentID: bot.id), soon.dueAt)

        let cancelled = try decode(AgentWake.self, from: messenger(bot, "--cancel-wake", soon.id.uuidString))
        XCTAssertEqual(cancelled.id, soon.id)
        XCTAssertEqual(try decode(AgentWakeList.self, from: messenger(bot, "--list-wakes")).pending.map(\.id), [later.id])
        XCTAssertNotEqual(messenger(bot, "--cancel-wake", soon.id.uuidString).exitCode, 0)
    }

    func testWakesAreKeptOutsideTheWorkspace() throws {
        let bot = try repository.createAgent(named: "Build Bot").agent
        _ = try decode(AgentWake.self, from: messenger(bot, "--wake-in", "1h", "--note", "Later"))
        let workspace = repository.directory(for: bot).standardizedFileURL.path
        let files = FileManager.default.enumerator(atPath: repository.storage(for: bot.id).package.path)?
            .compactMap { $0 as? String }.filter { $0.contains("wake") } ?? []
        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.allSatisfy { !repository.storage(for: bot.id).package.appendingPathComponent($0).path.hasPrefix(workspace + "/") })
    }

    func testDueWakesAreHandedOverOnceWithTheirNotes() throws {
        let bot = try repository.createAgent(named: "Build Bot").agent
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let wake = try repository.scheduleWake(agentID: bot.id, at: now.addingTimeInterval(600), note: "Check the build", now: now)
        XCTAssertFalse(try repository.takeDueWakes(agentID: bot.id, at: now.addingTimeInterval(599)))
        XCTAssertTrue(try repository.takeDueWakes(agentID: bot.id, at: now.addingTimeInterval(600)))
        XCTAssertFalse(try repository.takeDueWakes(agentID: bot.id, at: now.addingTimeInterval(601)))
        XCTAssertNil(repository.nextWakeDate(agentID: bot.id))

        let listed = try decode(AgentWakeList.self, from: messenger(bot, "--list-wakes"))
        XCTAssertEqual(listed.due, [wake])
        XCTAssertTrue(listed.pending.isEmpty)
        XCTAssertTrue(try decode(AgentWakeList.self, from: messenger(bot, "--list-wakes")).due.isEmpty)
    }

    func testWakesMustBeAtLeastFiveMinutesAheadAndCarryANote() throws {
        let bot = try repository.createAgent(named: "Build Bot").agent
        for arguments in [["--wake-in", "4m", "--note", "Too soon"], ["--wake-at", "2001-01-01T00:00:00Z", "--note", "Past"],
                          ["--wake-in", "10m"], ["--wake-in", "10m", "--note", " "], ["--wake-in", "soon", "--note", "Bad"]] {
            let command = repository.directory(for: bot).appendingPathComponent(".agents/skills/messenger/messenger")
            XCTAssertNotEqual(MessengerCLI.runDirect(arguments: [command.path] + arguments).exitCode, 0, "\(arguments)")
        }
        XCTAssertTrue(try decode(AgentWakeList.self, from: messenger(bot, "--list-wakes")).pending.isEmpty)
        XCTAssertEqual(try decode(AgentWake.self, from: messenger(bot, "--wake-in", "5m", "--note", "Just in time")).note, "Just in time")
    }

    func testAtMostThreeWakesWaitAtOnce() throws {
        let bot = try repository.createAgent(named: "Build Bot").agent
        for hours in 1...3 {
            XCTAssertEqual(messenger(bot, "--wake-in", "\(hours)h", "--note", "Wake \(hours)").exitCode, 0)
        }
        let refused = messenger(bot, "--wake-in", "4h", "--note", "Wake 4")
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertTrue(refused.standardError.contains("3"), refused.standardError)
    }

    func testTwelveWakesInARowNeedAMessageFromSomeoneElse() throws {
        let created = try repository.createAgent(named: "Build Bot")
        let bot = created.agent
        var now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        for index in 1...12 {
            _ = try repository.scheduleWake(agentID: bot.id, at: now.addingTimeInterval(300), note: "Wake \(index)", now: now)
            now.addTimeInterval(300)
            XCTAssertTrue(try repository.takeDueWakes(agentID: bot.id, at: now))
        }
        _ = try repository.sendAgentMessage(agentID: bot.id, conversationID: created.conversation.id, body: "Still going")
        XCTAssertThrowsError(try repository.scheduleWake(agentID: bot.id, at: now.addingTimeInterval(300), note: "13", now: now)) {
            XCTAssertTrue($0.localizedDescription.contains("12"), $0.localizedDescription)
        }
        try repository.append(ChatMessage(conversationID: created.conversation.id, author: .user, body: "Carry on",
                                          createdAt: now, delivery: .queued))
        XCTAssertNoThrow(try repository.scheduleWake(agentID: bot.id, at: now.addingTimeInterval(300), note: "13", now: now))
    }
}
