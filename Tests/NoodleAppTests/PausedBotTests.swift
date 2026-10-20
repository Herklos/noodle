import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class PausedBotTests: XCTestCase {
    func testPauseSummaryNamesTheReasonOnlyWhileTheBotWaitsForKick() {
        let id = UUID()
        func summary(_ phase: AgentRuntimePhase, _ failure: AgentRuntimeFailure? = nil) -> String? {
            AgentRuntimeSnapshot(agentID: id, phase: phase, detail: "Long detail", failure: failure).pauseSummary
        }
        XCTAssertEqual(summary(.failed, .recoveryFailed), "Paused: recovery interrupted")
        XCTAssertEqual(summary(.failed, .missingSession("s")), "Paused: session missing")
        XCTAssertEqual(summary(.failed, .usageLimit), "Paused: usage limit reached")
        XCTAssertEqual(summary(.failed, .authenticationRequired), "Paused: sign-in needed")
        XCTAssertEqual(summary(.failed, .safetyStop), "Paused: safety stop")
        XCTAssertEqual(summary(.failed), "Stopped")
        for phase in [AgentRuntimePhase.offline, .starting, .ready, .working] {
            XCTAssertNil(summary(phase, .recoveryFailed), "\(phase)")
        }
    }

    func testConversationsOfAPausedBotSayWhyAndOfferKick() throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        let group = try f.group()
        let ada = try f.runtime.start(f.a)
        try f.runtime.start(f.b)
        XCTAssertNil(f.store.pauseSummary(for: f.directA))
        XCTAssertTrue(f.store.agentsWaitingForKick(in: group).isEmpty)

        ada.transition(.failed, failure: .recoveryFailed)
        XCTAssertEqual(f.store.pauseSummary(for: f.directA), "Paused: recovery interrupted")
        XCTAssertEqual(f.store.agentsWaitingForKick(in: f.directA).map(\.id), [f.a.id])
        XCTAssertNil(f.store.pauseSummary(for: f.directB))
        XCTAssertEqual(f.store.pauseSummary(for: group), "Paused: Ada")
        XCTAssertEqual(f.store.agentsWaitingForKick(in: group).map(\.id), [f.a.id])

        ada.transition(.ready)
        XCTAssertNil(f.store.pauseSummary(for: f.directA))
        XCTAssertNil(f.store.pauseSummary(for: group))
    }

    func testPauseThatWaitsForKickIsAnnouncedOncePerPause() throws {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        let agent = try f.agent(), process = try f.start(agent)
        var announced: [UUID] = []
        f.runtime.onPaused = { announced.append($0) }

        process.transition(.failed)
        XCTAssertEqual(announced, [], "A stop with no reported failure restarts by itself")
        process.transition(.failed, failure: .authenticationRequired)
        XCTAssertEqual(announced, [], "Sign-in has its own notice")
        process.transition(.failed, failure: .recoveryFailed)
        XCTAssertEqual(announced, [agent.id])
        process.transition(.failed, failure: .recoveryFailed)
        XCTAssertEqual(announced, [agent.id], "The same pause is announced once")
        process.transition(.ready)
        process.transition(.failed, failure: .missingSession("session"))
        XCTAssertEqual(announced, [agent.id, agent.id])
    }
}
