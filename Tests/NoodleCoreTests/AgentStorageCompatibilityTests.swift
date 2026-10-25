import XCTest
@testable import NoodleCore

/// What Noodle still guarantees about bot packages now that the 0.13.0 and 0.14.0 migrations are
/// gone: older and damaged packages are refused everywhere and never rewritten, and are set aside
/// with why, so the other bots still load.
final class AgentStorageCompatibilityTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: URL(fileURLWithPath: "/bin/echo"))
        try repository.prepare()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    /// A current package whose configuration predates the stored backstory.
    private func withoutBackstory() throws -> AgentRecord {
        let agent = AgentRecord(displayName: "Legacy", harnessIdentifier: "codex")
        let layout = repository.storage(for: agent.id)
        try layout.create()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(agent).write(to: layout.configuration)
        try Data("# Noodle Agent\n\n## Backstory\n\nOriginal role\n".utf8).write(to: layout.workspace.appendingPathComponent("AGENTS.md"))
        return agent
    }

    private func message(_ body: () throws -> Void) -> String {
        do { try body(); return "" } catch { return error.localizedDescription }
    }

    /// A package from before 0.13.0: agent.json beside the bot's own files, without a marker.
    private func flat() throws -> AgentRecord {
        let agent = AgentRecord(displayName: "Flat", harnessIdentifier: "codex")
        let layout = repository.storage(for: agent.id)
        try FileManager.default.createDirectory(at: layout.package, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(agent).write(to: layout.configuration)
        try Data("Durable memory".utf8).write(to: layout.package.appendingPathComponent("memory.md"))
        return agent
    }

    /// The bots loading leaves out.
    private func setAside() throws -> [SetAsideAgent] { try repository.loadAgentsSettingAside().setAside }

    func testAFlatWorkspaceIsRefusedWithTheReleaseThatUpgradesIt() throws {
        let agent = try flat(), layout = repository.storage(for: agent.id)
        XCTAssertEqual(try repository.loadAgents(), [])
        let refused = try XCTUnwrap(setAside().first)
        XCTAssertEqual(refused.id, agent.id)
        XCTAssertEqual(refused.displayName, "Flat")
        XCTAssertEqual(refused.message, "This bot was made by a Noodle version older than 0.13.0. To upgrade it, back up your Noodle data, install Noodle 0.13.0 from https://github.com/pdparchitect/noodle/releases/tag/v0.13.0, open it, and accept each update it offers.")
        XCTAssertEqual(refused.helpURL, AgentStorageError.upgradeStepsURL)
        // Agent Host and Kick's recovery refuse it the same way.
        XCTAssertEqual(message { try layout.validate() }, refused.message)
        XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(agent))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.package.path).sorted(), ["agent.json", "memory.md"])
    }

    /// One older bot used to make loading fail for all of them (issue #195).
    func testAnOlderBotDoesNotKeepTheOthersFromLoading() throws {
        let current = try repository.createAgent(named: "Current").agent
        let old = try flat(), stored = try Data(contentsOf: repository.storage(for: old.id).configuration)
        let later = try repository.createAgent(named: "Later").agent
        XCTAssertEqual(Set(try repository.loadAgents().map(\.id)), [current.id, later.id])
        XCTAssertEqual(try setAside().map(\.id), [old.id])
        XCTAssertEqual(try Data(contentsOf: repository.storage(for: old.id).configuration), stored)
    }

    func testAPackageWithoutAStoredBackstoryIsRefusedEverywhere() throws {
        let agent = try withoutBackstory(), layout = repository.storage(for: agent.id)
        let original = try Data(contentsOf: layout.configuration)
        XCTAssertEqual(try repository.loadAgents(), [])
        XCTAssertEqual(try setAside().map(\.message), ["This bot was made by a Noodle version older than 0.14.0. To upgrade it, back up your Noodle data, install Noodle 0.14.0 from https://github.com/pdparchitect/noodle/releases/tag/v0.14.0, open it, and accept each update it offers."])
        XCTAssertEqual(try setAside().map(\.displayName), ["Legacy"])
        XCTAssertThrowsError(try repository.loadAgentBackstory(agent))
        XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(agent))
        XCTAssertThrowsError(try repository.updateAgentBackstory(agent, backstory: "Must not bypass the upgrade"))
        XCTAssertEqual(try Data(contentsOf: layout.configuration), original)
    }

    func testAnInvalidStoredBackstoryDoesNotFallBackToWorkspaceMarkdown() throws {
        for invalid in [NSNull(), 42, ["unexpected": "object"]] as [Any] {
            let agent = try withoutBackstory(), layout = repository.storage(for: agent.id)
            var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: layout.configuration)) as? [String: Any])
            config["backstory"] = invalid
            let bytes = try JSONSerialization.data(withJSONObject: config)
            try bytes.write(to: layout.configuration)
            XCTAssertThrowsError(try repository.loadAgentBackstory(agent))
            XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(agent))
            XCTAssertEqual(try Data(contentsOf: layout.configuration), bytes)
        }
    }

    func testAFutureLayoutIsRefused() throws {
        let created = try repository.createAgent(named: "Future"), layout = repository.storage(for: created.agent.id)
        try Data("{\"version\":99}".utf8).write(to: layout.package.appendingPathComponent(AgentStorageLayout.markerName))
        XCTAssertEqual(try repository.loadAgents(), [])
        XCTAssertEqual(try setAside().map(\.message), ["This bot uses storage version 99. Open a compatible version of Noodle."])
    }

    func testRedirectedWorkspaceAndIdentityMismatchAreRejected() throws {
        let created = try repository.createAgent(named: "New")
        let layout = repository.storage(for: created.agent.id)
        try FileManager.default.removeItem(at: layout.workspace)
        try FileManager.default.createSymbolicLink(at: layout.workspace, withDestinationURL: root)
        XCTAssertEqual(try repository.loadAgents(), [])
        XCTAssertEqual(try setAside().map(\.id), [created.agent.id])
        XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(created.agent))
        try FileManager.default.removeItem(at: layout.workspace)
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: layout.package, to: repository.agentsURL.appendingPathComponent(UUID().uuidString.lowercased()))
        XCTAssertEqual(try repository.loadAgents(), [])
        XCTAssertEqual(try setAside().map(\.message), ["The bot identifier does not match its storage folder. Restore the original UUID folder name."])
    }

    /// A package written by hand, or cut short by a crash or a full disk, can hold only its
    /// marker and agent.json; it gets the empty folders a new bot starts with and loads.
    func testAPackageWithOnlyItsConfigurationGetsItsFoldersBack() throws {
        let agent = AgentRecord(displayName: "Partial", harnessIdentifier: "claude-code")
        let layout = repository.storage(for: agent.id)
        try FileManager.default.createDirectory(at: layout.package, withIntermediateDirectories: false)
        try Data("{\"version\":1}".utf8).write(to: layout.package.appendingPathComponent(AgentStorageLayout.markerName))
        try AgentConfiguration(agent: agent, backstory: "Kept").save(to: layout)
        XCTAssertEqual(try repository.loadAgents().map(\.id), [agent.id])
        XCTAssertNoThrow(try layout.validate())
        try repository.synchronizeAgentWorkspace(agent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.workspace.appendingPathComponent("AGENTS.md").path))
        XCTAssertEqual(try repository.loadAgentBackstory(agent), "Kept")

        try FileManager.default.removeItem(at: layout.runtime)
        XCTAssertEqual(try repository.loadAgents().map(\.id), [agent.id])
        XCTAssertNoThrow(try layout.validate())
    }

    /// Only a package Noodle could otherwise load is completed.
    func testAPartialPackageThatCannotBeReadIsRefusedUntouched() throws {
        for configuration in ["{\"displayName\":\"Broken\"}", "not json"] {
            let layout = repository.storage(for: UUID())
            try FileManager.default.createDirectory(at: layout.package, withIntermediateDirectories: false)
            try Data("{\"version\":1}".utf8).write(to: layout.package.appendingPathComponent(AgentStorageLayout.markerName))
            try Data(configuration.utf8).write(to: layout.configuration)
            XCTAssertEqual(try repository.loadAgents(), [])
            XCTAssertEqual(try setAside().map(\.id), [UUID(uuidString: layout.package.lastPathComponent)])
            XCTAssertNil(try setAside().first?.displayName)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.package.path).sorted(),
                           [AgentStorageLayout.markerName, "agent.json"])
            try FileManager.default.removeItem(at: layout.package)
        }
    }

    /// Several loops ask for the bots every second; an unchanged package is not read again,
    /// but an edit or a redirect made since is still seen.
    func testUnchangedPackagesAreNotReadAgainButChangesAreSeen() throws {
        let created = try repository.createAgent(named: "Steady")
        let layout = repository.storage(for: created.agent.id)
        XCTAssertEqual(try repository.loadAgents().map(\.displayName), ["Steady"])
        let reads = repository.agentRecords.reads
        _ = try repository.loadAgents()
        _ = try repository.loadAgents()
        XCTAssertEqual(repository.agentRecords.reads, reads)

        // Rewritten in place at the same size, as an edit from outside Noodle may be.
        let original = try Data(contentsOf: layout.configuration)
        let edited = try XCTUnwrap(String(data: original, encoding: .utf8)).replacingOccurrences(of: "Steady", with: "Sturdy")
        try Data(edited.utf8).write(to: layout.configuration)
        XCTAssertEqual(try repository.loadAgents().map(\.displayName), ["Sturdy"])

        _ = try repository.updateAgent(created.agent, displayName: "Renamed", harnessIdentifier: created.agent.harnessIdentifier,
                                       modelIdentifier: nil, reasoningEffort: nil)
        XCTAssertEqual(try repository.loadAgents().map(\.displayName), ["Renamed"])

        try FileManager.default.removeItem(at: layout.workspace)
        try FileManager.default.createSymbolicLink(at: layout.workspace, withDestinationURL: root)
        XCTAssertEqual(try repository.loadAgents(), [])
        try FileManager.default.removeItem(at: layout.workspace)
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: false)
        XCTAssertEqual(try repository.loadAgents().map(\.displayName), ["Renamed"])

        try FileManager.default.removeItem(at: layout.package)
        XCTAssertEqual(try repository.loadAgents(), [])
    }

    func testCopiedPackageIsDiscoveredAndManagedLinksRefresh() throws {
        let created = try repository.createAgent(named: "Copy", backstory: "Same core")
        let destination = WorkspaceRepository(rootURL: root.appendingPathComponent("Destination"), launcherExecutableURL: URL(fileURLWithPath: "/bin/cat"))
        try destination.prepare()
        try FileManager.default.copyItem(at: repository.storage(for: created.agent.id).package,
                                         to: destination.storage(for: created.agent.id).package)
        XCTAssertEqual(try destination.loadAgents(), try repository.loadAgents())
        try destination.synchronizeAgentWorkspace(created.agent)
        XCTAssertEqual(try destination.loadAgentBackstory(created.agent), "Same core")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.directory(for: created.agent)
            .appendingPathComponent(".agents/skills/messenger/messenger").path), "/bin/cat")
    }
}
