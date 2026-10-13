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

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func utcDate(_ raw: String) -> Date { ISO8601DateFormatter().date(from: raw)! }

    func testCronSchedulesFindTheirNextTime() throws {
        // 2026-10-17 is a Saturday.
        let saturday = utcDate("2026-10-17T12:00:00Z")
        let cases: [(String, String)] = [
            ("30 9 * * 1-5", "2026-10-19T09:30:00Z"),
            ("*/15 * * * *", "2026-10-17T12:15:00Z"),
            ("0 9,17 * * *", "2026-10-17T17:00:00Z"),
            ("0 0 1 * *", "2026-11-01T00:00:00Z"),
            ("0 8 * * sun", "2026-10-18T08:00:00Z"),
            ("0 8 * * 7", "2026-10-18T08:00:00Z"),
            ("0 0 1 jan *", "2027-01-01T00:00:00Z"),
            // With both day fields restricted, either one matching is enough.
            ("0 6 25 * 1", "2026-10-19T06:00:00Z"),
            ("0 0 29 2 *", "2028-02-29T00:00:00Z"),
            ("@daily", "2026-10-18T00:00:00Z"),
            ("@hourly", "2026-10-17T13:00:00Z"),
        ]
        for (expression, expected) in cases {
            let schedule = try XCTUnwrap(CronSchedule(expression), expression)
            XCTAssertEqual(schedule.nextDate(after: saturday, calendar: utc), utcDate(expected), expression)
        }
        for expression in ["60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8", "* * * *",
                           "* * * * * *", "5-1 * * * *", "*/0 * * * *", "nonsense", "", "@often"] {
            XCTAssertNil(CronSchedule(expression), expression)
        }
        XCTAssertNil(try XCTUnwrap(CronSchedule("0 0 30 2 *")).nextDate(after: saturday, calendar: utc))
    }

    func testRecurringWakeComesBackAfterFiring() throws {
        let created = try repository.createAgent(named: "Report Bot")
        let bot = created.agent
        var now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let wake = try repository.scheduleWake(agentID: bot.id, every: "*/10 * * * *", note: "Post the report", now: now)
        XCTAssertEqual(wake.schedule, "*/10 * * * *")
        XCTAssertGreaterThanOrEqual(wake.dueAt.timeIntervalSince(now), AgentWakeLimits.minimumDelay)

        // Recurring wakes keep firing without anyone writing; one-off wakes would be refused by now.
        var dueAt = wake.dueAt
        for _ in 1...(AgentWakeLimits.withoutOutsideMessages + 2) {
            now = dueAt
            XCTAssertTrue(try repository.takeDueWakes(agentID: bot.id, at: now))
            let listed = try repository.listWakes(agentID: bot.id)
            XCTAssertEqual(listed.due.map(\.id), [wake.id])
            XCTAssertEqual(listed.due.first?.dueAt, dueAt)
            let next = try XCTUnwrap(listed.pending.first)
            XCTAssertEqual(next.id, wake.id)
            XCTAssertEqual(next.dueAt.timeIntervalSince(dueAt), 600)
            dueAt = next.dueAt
        }
        XCTAssertNoThrow(try repository.scheduleWake(agentID: bot.id, at: now.addingTimeInterval(600), note: "One-off", now: now))
        XCTAssertEqual(try repository.cancelWake(agentID: bot.id, id: wake.id).id, wake.id)
        XCTAssertEqual(try repository.listWakes(agentID: bot.id).pending.map(\.note), ["One-off"])
    }

    func testRecurringWakesSkipTimesCloserThanTheMinimumDelay() throws {
        let bot = try repository.createAgent(named: "Report Bot").agent
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let wake = try repository.scheduleWake(agentID: bot.id, every: "* * * * *", note: "Too often", now: now)
        XCTAssertEqual(wake.dueAt.timeIntervalSince(now), AgentWakeLimits.minimumDelay)
        XCTAssertTrue(try repository.takeDueWakes(agentID: bot.id, at: wake.dueAt))
        XCTAssertEqual(repository.nextWakeDate(agentID: bot.id)?.timeIntervalSince(wake.dueAt), AgentWakeLimits.minimumDelay)
    }

    func testBotSchedulesRecurringWakesWithCron() throws {
        let bot = try repository.createAgent(named: "Report Bot").agent
        let wake = try decode(AgentWake.self, from: messenger(bot, "--wake-every", "0 9 * * 1-5", "--note", "Morning report"))
        XCTAssertEqual(wake.schedule, "0 9 * * 1-5")
        XCTAssertEqual(Calendar.current.dateComponents([.hour, .minute], from: wake.dueAt), DateComponents(hour: 9, minute: 0))
        XCTAssertEqual(try decode(AgentWakeList.self, from: messenger(bot, "--list-wakes")).pending, [wake])
        for arguments in [["--wake-every", "0 25 * * *", "--note", "Bad"], ["--wake-every", "0 0 30 2 *", "--note", "Never"],
                          ["--wake-every", "0 9 * * *"]] {
            let command = repository.directory(for: bot).appendingPathComponent(".agents/skills/messenger/messenger")
            XCTAssertNotEqual(MessengerCLI.runDirect(arguments: [command.path] + arguments).exitCode, 0, "\(arguments)")
        }
    }
}
