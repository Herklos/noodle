import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

/// Plan limits reach Settings from the messages harnesses already send during their turns.
@MainActor final class SubscriptionUsageRuntimeTests: XCTestCase {
    /// Claude Code may report a limit as a turn ends, after Noodle stops following the turn.
    func testClaudeRateLimitEventsReachTheRuntimeOutsideATurn() async throws {
        let f = try HarnessRuntimeFixture(), wire = HarnessWire()
        defer { f.cleanUp() }
        var received: [String] = []
        let process = ClaudeAgentProcess(agent: .init(displayName: "Claude", harnessIdentifier: "claudeCode"),
            executableURL: f.root, workspaceURL: f.workspace, extendedAccess: true, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in },
            onActivity: { received.append($0["type"] as? String ?? "") }, makeConnection: { wire },
            sleep: { try await f.clock.sleep($0) })
        f.processes.append(process)
        process.start()
        try await f.wait { process.canReceiveHeartbeat }
        let session = try XCTUnwrap(wire.launches.last?.2)
        wire.emit(["type": "rate_limit_event", "session_id": UUID().uuidString,
                   "rate_limit_info": ["status": "allowed", "rateLimitType": "five_hour", "utilization": 0.5]])
        wire.emit(["type": "rate_limit_event", "session_id": session.uuidString,
                   "rate_limit_info": ["status": "allowed", "rateLimitType": "five_hour", "utilization": 0.4]])
        try await f.wait { !received.isEmpty }
        XCTAssertEqual(received, ["rate_limit_event"])
    }

    /// Codex sends account limits without a thread, so they are not tied to the current turn.
    func testCodexAccountRateLimitUpdatesReachTheRuntime() async throws {
        let f = try HarnessRuntimeFixture(), wire = HarnessWire()
        defer { f.cleanUp() }
        var received: [[String: Any]] = []
        let process = CodexAgentProcess(agent: .init(displayName: "Codex", harnessIdentifier: "codex"),
            executableURL: f.root, workspaceURL: f.workspace, extendedAccess: true, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in },
            onActivity: { received.append($0) }, makeConnection: { wire }, sleep: { try await f.clock.sleep($0) })
        f.processes.append(process)
        process.start()
        try await f.openCodex(wire)
        wire.emit(["method": "account/rateLimits/updated",
                   "params": ["rateLimits": ["primary": ["usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1_800_000_000]]]])
        try await f.wait { !received.isEmpty }
        XCTAssertEqual(received.first?["method"] as? String, "account/rateLimits/updated")
        let primary = ((received.first?["params"] as? [String: Any])?["rateLimits"] as? [String: Any])?["primary"] as? [String: Any]
        XCTAssertEqual(primary?["usedPercent"] as? Int, 12)
    }

    /// Each reading goes to the login the bot runs on: the system one, or its profile.
    func testReadingsAreKeptPerAccount() throws {
        let f = try RuntimeCoordinatorFixture()
        defer { f.cleanUp() }
        let claude = try f.agent("Ada", harness: .claudeCode), codex = try f.agent("Lin", harness: .codex)
        let profile = UUID()
        try f.repository.updateAgentHarnessProfile(codex, profile: profile)
        try f.start(claude).launch.onActivity(["type": "rate_limit_event", "session_id": "s",
            "rate_limit_info": ["status": "allowed", "rateLimitType": "five_hour", "utilization": 0.25, "resetsAt": 1_800_003_600]])
        try f.start(codex).launch.onActivity(["method": "account/rateLimits/updated", "params": ["rateLimits": [
            "primary": ["usedPercent": 64, "windowDurationMins": 300, "resetsAt": 1_800_010_000],
            "secondary": ["usedPercent": 9, "windowDurationMins": 10_080, "resetsAt": 1_800_500_000]]]])
        // Token usage is not a plan limit.
        try XCTUnwrap(f.factory.processes.last).launch.onActivity(["method": "thread/tokenUsage/updated", "params": [:]])

        let store = f.runtime.subscriptionUsage
        XCTAssertEqual(store.usage(.claudeCode, profile: nil)?.windows.map(\.usedPercent), [25])
        XCTAssertEqual(store.usage(.claudeCode, profile: nil)?.updatedAt, f.clock.date)
        XCTAssertNil(store.usage(.codex, profile: nil))
        XCTAssertEqual(store.usage(.codex, profile: profile)?.windows.map(\.usedPercent), [64, 9])
        XCTAssertEqual(store.accounts.count, 2)
    }

    /// Settings shows the last reading after Noodle restarts; a deleted profile's goes with it.
    func testReadingsSurviveARestartUntilTheirProfileIsDeleted() throws {
        let suite = "Noodle.SubscriptionUsageTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = SubscriptionUsage(windows: [SubscriptionUsageWindow(id: "primary", minutes: 300, usedPercent: 20,
                                                                        resetsAt: now.addingTimeInterval(3_600))], updatedAt: now)
        let store = SubscriptionUsageStore(defaults: defaults)
        store.record(usage, provider: .codex, profile: nil)
        store.record(usage, provider: .codex, profile: profile)
        // A reading taken earlier, such as a slow Settings check, does not replace a newer one.
        var older = usage
        older.updatedAt = now.addingTimeInterval(-60)
        older.windows[0].usedPercent = 5
        store.record(older, provider: .codex, profile: nil)

        let reopened = SubscriptionUsageStore(defaults: defaults)
        XCTAssertEqual(reopened.usage(.codex, profile: nil), usage)
        XCTAssertEqual(reopened.usage(.codex, profile: profile), usage)
        reopened.forget(.codex, profile: profile)
        XCTAssertNil(SubscriptionUsageStore(defaults: defaults).usage(.codex, profile: profile))
        XCTAssertEqual(SubscriptionUsageStore(defaults: defaults).usage(.codex, profile: nil), usage)
    }

    /// A deleted profile is signed out, so its account has no limits left to show.
    func testDeletingAProfileForgetsItsReading() throws {
        let f = try RuntimeCoordinatorFixture()
        defer { f.cleanUp() }
        let controller = HarnessProfilesController(store: f.repository.harnessProfiles)
        controller.subscriptionUsage = f.runtime.subscriptionUsage
        let profile = try controller.create(provider: .codex, named: "Work")
        let usage = SubscriptionUsage(windows: [SubscriptionUsageWindow(id: "primary", minutes: 300, usedPercent: 1, resetsAt: nil)],
                                      updatedAt: f.clock.date)
        f.runtime.subscriptionUsage.record(usage, provider: .codex, profile: profile.id)
        try controller.delete(profile)
        XCTAssertNil(f.runtime.subscriptionUsage.usage(.codex, profile: profile.id))
    }
}
