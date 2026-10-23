import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

/// A bot whose harness runs out of usage continues on the next one in Settings › Harnesses, and comes back later.
@MainActor final class HarnessFallbackTests: XCTestCase {
    private func fixture(fallbacks: [HarnessProvider] = [.codex, .claudeCode]) throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.runtime.harnesses.setFallbacks(fallbacks)
        f.runtime.harnesses.setFallback(on: true)
        return f
    }

    private func codexBot(_ f: RuntimeCoordinatorFixture) throws -> AgentRecord {
        var agent = try f.agent("Ada", harness: .codex)
        agent.modelIdentifier = "gpt-5.5"
        agent.reasoningEffort = "high"
        return agent
    }

    func testUsageLimitContinuesOnTheNextHarnessAndSaysSo() throws {
        let f = try fixture(), agent = try codexBot(f)
        var lines: [String] = [], paused: [UUID] = []
        f.runtime.onHarnessSwitch = { id, line in XCTAssertEqual(id, agent.id); lines.append(line) }
        f.runtime.onPaused = { paused.append($0) }
        let codex = try f.start(agent)

        codex.transition(.failed, detail: "Codex reached its usage limit", failure: .usageLimit)

        let claude = try XCTUnwrap(f.factory.processes.last)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertEqual(claude.launch.provider, .claudeCode)
        XCTAssertEqual(claude.configuration.harnessIdentifier, HarnessProvider.claudeCode.rawValue)
        XCTAssertNil(claude.configuration.modelIdentifier, "The fallback uses its harness's default model")
        XCTAssertNil(claude.configuration.reasoningEffort)
        XCTAssertEqual(lines, ["Codex is out of usage, continuing on Claude Code"])
        XCTAssertEqual(paused, [], "A bot that continues elsewhere is not paused")
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
        XCTAssertEqual(f.runtime.runningHarness(for: agent.id), .claudeCode)
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == agent.id }?.harnessIdentifier,
                       HarnessProvider.codex.rawValue, "The switch is runtime state, not saved with the bot")

        f.runtime.refresh(agents: [agent], repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 2, "Refreshing with the saved bot must not undo the switch")
    }

    func testBusyErrorsAndAnOffSettingDoNotSwitch() throws {
        let off = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in off.cleanUp() }
        off.runtime.harnesses.setFallbacks([.codex, .claudeCode])
        var paused: [UUID] = []
        off.runtime.onPaused = { paused.append($0) }
        let agent = try off.agent(harness: .codex)
        try off.start(agent).transition(.failed, failure: .usageLimit)
        XCTAssertEqual(off.factory.processes.count, 1, "Off by default")
        XCTAssertEqual(paused, [agent.id])

        let f = try fixture(), bot = try codexBot(f), codex = try f.start(bot)
        codex.transition(.failed, detail: "The Codex model service is busy.")
        XCTAssertNil(f.runtime.runningHarness(for: bot.id))
        XCTAssertTrue(f.factory.processes.allSatisfy { $0.launch.provider == .codex })
    }

    func testOnlyHarnessesThatAreOnInstalledAndHaveUsageLeftAreUsed() throws {
        let f = try fixture(fallbacks: [.grokBuild, .claudeCode])
        let agent = try codexBot(f)
        var paused: [UUID] = []
        f.runtime.onPaused = { paused.append($0) }
        f.runtime.subscriptionUsage.record(SubscriptionUsage(windows: [SubscriptionUsageWindow(id: "five_hour", minutes: 300,
            usedPercent: 100, resetsAt: f.clock.date.addingTimeInterval(3600))], updatedAt: f.clock.date), provider: .claudeCode, profile: nil)
        f.runtime.setHarness(.grokBuild, on: false)

        try f.start(agent).transition(.failed, failure: .usageLimit)

        XCTAssertEqual(f.factory.processes.count, 1, "Grok Build is off and Claude Code is out of usage too")
        XCTAssertEqual(paused, [agent.id], "With nowhere to go the bot pauses as before")
        XCTAssertNil(f.runtime.runningHarness(for: agent.id))
    }

    func testAFallbackThatRunsOutTooPausesWhenNothingIsLeft() throws {
        let f = try fixture(), agent = try codexBot(f)
        var paused: [UUID] = []
        f.runtime.onPaused = { paused.append($0) }
        try f.start(agent).transition(.failed, failure: .usageLimit)
        let claude = try XCTUnwrap(f.factory.processes.last)
        claude.transition(.failed, failure: .usageLimit)
        XCTAssertEqual(f.factory.processes.count, 2, "Codex is still out of usage")
        XCTAssertEqual(paused, [agent.id])
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).failure, .usageLimit)
    }

    func testReturnsAtAnIdlePointOnceTheResetAndTheCooldownHavePassed() throws {
        let f = try fixture(), agent = try codexBot(f)
        var lines: [String] = []
        f.runtime.onHarnessSwitch = { lines.append($1) }
        let start = f.clock.date
        try f.start(agent).transition(.failed, failure: .usageLimit, usageResetsAt: start.addingTimeInterval(10 * 60))
        let claude = try XCTUnwrap(f.factory.processes.last)
        claude.canReceiveHeartbeat = true

        f.clock.date = start.addingTimeInterval(11 * 60)
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 2, "A primary that just reset waits out the cooldown")

        f.clock.date = start.addingTimeInterval(31 * 60)
        claude.canReceiveHeartbeat = false
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 2, "A bot at work is never switched")

        claude.canReceiveHeartbeat = true
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        let codex = try XCTUnwrap(f.factory.processes.last)
        XCTAssertEqual(f.factory.processes.count, 3)
        XCTAssertEqual(codex.launch.provider, .codex)
        XCTAssertEqual(codex.configuration, agent, "Back on its own harness, model and effort")
        XCTAssertNil(f.runtime.runningHarness(for: agent.id))
        XCTAssertEqual(lines.last, "Back on Codex")
    }

    func testAPrimaryThatRunsOutAgainSoonAfterReturningWaitsLonger() throws {
        let f = try fixture(), agent = try codexBot(f)
        let start = f.clock.date
        try f.start(agent).transition(.failed, failure: .usageLimit, usageResetsAt: start.addingTimeInterval(60))
        try XCTUnwrap(f.factory.processes.last).canReceiveHeartbeat = true
        f.clock.date = start.addingTimeInterval(31 * 60)
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        XCTAssertNil(f.runtime.runningHarness(for: agent.id))

        // Out again five minutes after coming back: the next stay away is twice as long.
        f.clock.date = start.addingTimeInterval(36 * 60)
        try XCTUnwrap(f.factory.processes.last).transition(.failed, failure: .usageLimit, usageResetsAt: f.clock.date.addingTimeInterval(60))
        XCTAssertEqual(f.runtime.runningHarness(for: agent.id), .claudeCode)
        let claude = try XCTUnwrap(f.factory.processes.last)
        claude.canReceiveHeartbeat = true
        f.clock.date = start.addingTimeInterval(67 * 60)
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        XCTAssertEqual(f.runtime.runningHarness(for: agent.id), .claudeCode, "Thirty minutes is not enough after a flap")
        f.clock.date = start.addingTimeInterval(97 * 60)
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        XCTAssertNil(f.runtime.runningHarness(for: agent.id))
    }

    func testKickGoesBackToTheBotsOwnHarness() throws {
        let f = try fixture(), agent = try codexBot(f)
        try f.start(agent).transition(.failed, failure: .usageLimit, usageResetsAt: f.clock.date.addingTimeInterval(3 * 3600))
        XCTAssertEqual(f.runtime.runningHarness(for: agent.id), .claudeCode)

        XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository), "Going back needs no confirmation")

        let codex = try XCTUnwrap(f.factory.processes.last)
        XCTAssertEqual(f.factory.processes.count, 3)
        XCTAssertEqual(codex.launch.provider, .codex)
        XCTAssertNil(f.runtime.runningHarness(for: agent.id))
    }

    func testTheSwitchPostsASystemLineInTheBotsConversation() throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.runtime.harnesses.setFallbacks([.codex, .claudeCode])
        f.store.runtime.harnesses.setFallback(on: true)
        try f.runtime.start(f.a).transition(.failed, failure: .usageLimit)

        let line = try XCTUnwrap(f.store.messages(for: f.directA).last)
        XCTAssertEqual(line.author, .system)
        XCTAssertEqual(line.body, "Codex is out of usage, continuing on Claude Code")
        XCTAssertEqual(try f.repository.loadMessages(conversationID: f.directA.id).last?.id, line.id)
    }
}
