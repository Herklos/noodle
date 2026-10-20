import Foundation
import HubCore
import HubLink
import NoodleCore
import NoodleRuntime
import XCTest

/// A plan's token limit holds its users' bots once they used it up, until the tokens are older than its period.
@MainActor final class HubTokenLimitTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let runtime: AgentRuntimeCoordinator
        let processes: () -> [FakeProcess]
        let plan: HubPlan
        let ada: HubUser
        let kai: AgentRecord
        let conversation: UUID
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> Fixture {
        let (runtime, processes) = try fakeRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-tokens-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil, runtime: runtime)
        try hub.repository.prepare()
        hub.tokenLimits.now = { [unowned self] in self.now }
        let plan = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: plan)
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: plan)
        hub.bots.watch()
        addTeardownBlock { await MainActor.run { hub.bots.stopWatching() } }
        let bot = try hub.bots.create(LinkBotDraft(name: "Kai", provider: "codex"), for: ada)
        let kai = try XCTUnwrap(hub.repository.loadAgents().first { $0.id == bot.id })
        return Fixture(hub: hub, runtime: runtime, processes: processes, plan: plan, ada: ada, kai: kai,
                       conversation: bot.conversationID)
    }

    /// What the runtime reports for one model call of Kai's.
    private func use(_ f: Fixture, input: Int, cacheRead: Int = 0, at seconds: TimeInterval) {
        f.runtime.onUsage?(UsageSample(date: start.addingTimeInterval(seconds), agentID: f.kai.id, agentName: "Kai",
                                       harness: "codex", model: "gpt-5", tokens: UsageTokens(input: input, cacheRead: cacheRead),
                                       costUSD: nil))
    }

    private func send(_ f: Fixture, _ body: String) throws {
        _ = try f.hub.bots.send(body, id: UUID(), in: f.conversation, for: f.ada)
    }

    func testABotFinishesItsTurnThenWaitsUntilItsOwnersTokensLeaveThePeriod() throws {
        let f = try fixture()
        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 1_000, length: 1, unit: .days), in: f.plan)
        f.runtime.start(agent: f.kai, repository: f.hub.repository)
        let turn = try XCTUnwrap(f.processes().last)
        turn.set(.working)

        // Cache reads repeat input already counted, so they do not count again.
        use(f, input: 900, cacheRead: 50_000, at: 0)
        XCTAssertNil(f.hub.tokenLimits.holds[f.ada.id])
        XCTAssertEqual(f.hub.tokenLimits.used(by: f.ada)?.tokens, 900)
        now = start.addingTimeInterval(3600)
        use(f, input: 100, at: 3600)
        // The 900 tokens leave the day a day after they were used, leaving 100.
        XCTAssertEqual(f.hub.tokenLimits.holds[f.ada.id], start.addingTimeInterval(86_400))

        // The turn under way goes on.
        XCTAssertEqual(turn.stops, 0)
        XCTAssertEqual(f.runtime.snapshot(for: f.kai.id).phase, .working)
        XCTAssertThrowsError(try send(f, "Hello")) { error in
            XCTAssertEqual(error.localizedDescription,
                           "You have used the 1,000 tokens your plan allows per day. Your bots can continue in 23 hours.")
        }
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: f.conversation).filter { $0.author == .user }.count, 0)

        // Once it ends, the bot stops before taking another, and says until when it waits.
        turn.set(.ready)
        XCTAssertEqual(turn.stops, 1)
        let held = f.runtime.snapshot(for: f.kai.id)
        XCTAssertEqual(held.phase, .offline)
        XCTAssertTrue(held.detail.hasPrefix("Token limit reached."), held.detail)
        f.runtime.notify([f.kai], repository: f.hub.repository)
        f.runtime.reconcile(agents: [f.kai], repository: f.hub.repository, immediately: true)
        f.runtime.refresh(agents: [f.kai], repository: f.hub.repository)
        XCTAssertEqual(f.processes().count, 1, "No new turn starts while it waits")
        XCTAssertEqual(f.runtime.snapshot(for: f.kai.id).detail, held.detail)

        // A day after the first tokens, the rest are under the limit, and the bot starts again.
        now = start.addingTimeInterval(86_400 - 1)
        f.hub.tokenLimits.checkExpired()
        XCTAssertNotNil(f.hub.tokenLimits.holds[f.ada.id])
        now = start.addingTimeInterval(86_400)
        f.hub.tokenLimits.checkExpired()
        XCTAssertNil(f.hub.tokenLimits.holds[f.ada.id])
        XCTAssertEqual(f.processes().count, 2)
        XCTAssertTrue(try XCTUnwrap(f.processes().last).isAlive)
        XCTAssertEqual(f.hub.tokenLimits.used(by: f.ada)?.tokens, 100)
        XCTAssertNoThrow(try send(f, "Hello again"))
    }

    /// Changing a plan's limit holds or lets go its users at once, counting tokens already used.
    func testChangingAPlansLimitTakesEffectStraightAway() throws {
        let f = try fixture()
        f.runtime.start(agent: f.kai, repository: f.hub.repository)
        use(f, input: 500, at: 0)
        XCTAssertNil(f.hub.tokenLimits.used(by: f.ada), "No limit by default")
        XCTAssertNoThrow(try send(f, "Hello"))

        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 400, length: 2, unit: .hours), in: f.plan)
        XCTAssertEqual(f.hub.tokenLimits.holds[f.ada.id], start.addingTimeInterval(2 * 3600))
        XCTAssertEqual(f.runtime.snapshot(for: f.kai.id).phase, .offline, "An idle bot stops at once")
        XCTAssertEqual(f.processes().first?.stops, 1)
        XCTAssertThrowsError(try send(f, "Again"))

        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 600, length: 2, unit: .hours), in: f.plan)
        XCTAssertNil(f.hub.tokenLimits.holds[f.ada.id])
        XCTAssertEqual(f.processes().count, 2)
        XCTAssertNoThrow(try send(f, "Again"))

        // So does moving someone to a plan with a lower limit.
        let small = try f.hub.access.addPlan(named: "Small")
        f.hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: small)
        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 100, length: 1, unit: .weeks), in: small)
        f.hub.access.move(f.ada, to: small)
        XCTAssertEqual(f.hub.tokenLimits.holds[f.ada.id], start.addingTimeInterval(7 * 86_400))
    }

    /// Someone a bot is shared with talks with it on its owner's plan, so its owner's limit holds it for them too.
    func testSomeoneABotIsSharedWithIsToldItsOwnersTokensAreUsedUp() throws {
        let f = try fixture()
        let grace = try f.hub.access.addUser(named: "Grace")
        let shared = try f.hub.bots.share(f.kai.id, with: [grace.id], for: f.ada)
        let theirs = try XCTUnwrap(f.hub.bots.bots(for: grace).first { $0.id == shared.id })
        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 10, length: 3, unit: .days), in: f.plan)
        use(f, input: 10, at: 0)
        XCTAssertThrowsError(try f.hub.bots.send("Hi", id: UUID(), in: theirs.conversationID, for: grace)) { error in
            XCTAssertEqual(error.localizedDescription, "Kai has used the tokens its owner’s plan allows. It can continue in 3 days.")
        }
        // Grace's own plan has no limit; what Ada's bot used is not hers.
        XCTAssertNil(f.hub.tokenLimits.holds[grace.id])
    }
}
