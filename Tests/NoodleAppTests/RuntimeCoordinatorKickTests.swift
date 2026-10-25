import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class RuntimeCoordinatorKickTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    private func missingSession(_ f: RuntimeCoordinatorFixture, provider: HarnessProvider = .grokBuild) throws -> (AgentRecord, RuntimeProcessFixture, URL, String) {
        let agent = try f.agent(harness: provider), process = try f.start(agent)
        let url = f.repository.storage(for: agent.id).sessionState(provider: provider, extendedAccess: false)
        let id = UUID().uuidString
        try ACPSessionState(sessionID: id).save(to: url)
        process.transition(.failed, failure: .missingSession(id))
        return (agent, process, url, id)
    }

    func testOrdinaryKickRestartsWithoutConfirmationOrSessionChanges() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.transition(.failed)
        XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository))
        XCTAssertEqual(process.stops, 1)
        XCTAssertEqual(f.factory.processes.count, 2)
    }

    func testSignInRetryRestartsBotWhoseStatusChanged() throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode), process = try f.start(agent)
        process.transition(.failed, failure: .authenticationRequired)
        var updated = agent
        updated.status = "Reviewing PRs"
        let request = try XCTUnwrap(f.runtime.kick(agent: updated, repository: f.repository))
        f.runtime.confirmKick(request, repository: f.repository)
        XCTAssertEqual(process.stops, 1, "A bot's own status line is not a configuration change")
        XCTAssertEqual(f.factory.processes.count, 2)
    }

    func testKickRetriesFailedSettingsRestartAndPreservesUnfinishedWork() throws {
        let f = try fixture(), agent = try f.agent(), old = try f.start(agent)
        old.hasInterruptedWork = true
        old.transition(.working)
        old.automaticallyStops = false
        let state = f.repository.storage(for: agent.id).sessionState(provider: .codex, extendedAccess: false)
        try Data("saved session".utf8).write(to: state)
        var recovery = AgentTurnRecovery(sessionStateURL: state)
        try recovery.begin()
        let marker = try Data(contentsOf: state.appendingPathExtension("unfinished"))
        var updated = agent
        updated.updatedAt = agent.updatedAt.addingTimeInterval(1)
        f.runtime.restart(agent: updated, repository: f.repository)
        old.finishStop(false)
        let failure = f.runtime.snapshot(for: agent.id)
        f.runtime.refresh(agents: [updated], repository: f.repository)
        f.runtime.reconcile(agents: [updated], repository: f.repository, immediately: true)
        f.runtime.notify([updated], repository: f.repository)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id), failure)
        XCTAssertEqual(old.stops, 1, "Automatic refresh must keep the failed stop available for explicit retry")

        for attempt in 2...3 {
            XCTAssertNil(f.runtime.kick(agent: updated, repository: f.repository))
            XCTAssertEqual(old.stops, attempt, "Kick must retry the original runtime's stop")
            XCTAssertEqual(f.factory.processes.count, 1, "Never overlap an unconfirmed old runtime")
            old.finishStop(attempt == 3)
        }
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertEqual(f.factory.processes.last?.configuration, updated)
        XCTAssertTrue(f.factory.processes.last!.launch.recoverInterruptedWork)
        XCTAssertEqual(try Data(contentsOf: state), Data("saved session".utf8))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathExtension("unfinished")), marker)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }

    func testKickAfterFailedAccessRevocationRetainsRestrictedAccess() throws {
        let f = try fixture(), agent = try f.agent()
        f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
        let old = try XCTUnwrap(f.factory.processes.last)
        old.automaticallyStops = false
        f.runtime.setExtendedAccess(false, agent: agent, repository: f.repository)
        old.finishStop(false)
        XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository))
        XCTAssertEqual(old.stops, 2)
        XCTAssertEqual(f.factory.processes.count, 1)
        old.finishStop(true)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertFalse(f.factory.processes.last!.launch.extendedAccess)
    }

    func testMissingSessionDoesNothingUntilConfirmedThenPreservesWorkAndOtherAccessMode() throws {
        for provider in [HarnessProvider.grokBuild, .openCode] {
            let f = try fixture(), (agent, process, url, id) = try missingSession(f, provider: provider)
            let original = try Data(contentsOf: url)
            let otherMode = f.repository.storage(for: agent.id).sessionState(provider: provider, extendedAccess: true)
            try original.write(to: otherMode)
            var work = AgentTurnRecovery(sessionStateURL: url)
            try work.begin()
            let marker = try Data(contentsOf: url.appendingPathExtension("unfinished"))
            let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
            XCTAssertEqual(request.failure, .missingSession(id))
            XCTAssertTrue(request.message.contains("may be lost"))
            XCTAssertEqual(process.stops, 0, "Opening or cancelling the confirmation must leave the bot alone")
            XCTAssertEqual(try Data(contentsOf: url), original)

            process.automaticallyStops = false
            f.runtime.confirmKick(request, repository: f.repository)
            XCTAssertEqual(try Data(contentsOf: url), original, "Wait for the exact runtime to stop before changing state")
            process.finishStop(true)
            let state = try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url))
            XCTAssertNil(state.sessionID)
            XCTAssertEqual(state.previousSessionIDs, [id])
            XCTAssertTrue(state.needsHistoryRecovery)
            XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("unfinished")), marker)
            XCTAssertEqual(try Data(contentsOf: otherMode), original)
            XCTAssertEqual(f.factory.processes.count, 2)
            f.runtime.confirmKick(request, repository: f.repository)
            XCTAssertEqual(f.factory.processes.count, 2, "Confirmation cannot be replayed")
        }
    }

    func testOldConfirmationCannotResetReplacementOrRemovedBot() throws {
        for remove in [false, true] {
            let f = try fixture(), (agent, _, url, _) = try missingSession(f)
            let original = try Data(contentsOf: url)
            let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
            if remove { f.runtime.refresh(agents: []) }
            else { f.runtime.restart(agent: agent, repository: f.repository) }
            let count = f.factory.processes.count
            f.runtime.confirmKick(request, repository: f.repository)
            XCTAssertEqual(f.factory.processes.count, count)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testUnconfirmedStopAndShutdownPreserveSession() throws {
        for shutdown in [false, true] {
            let f = try fixture(), (agent, process, url, _) = try missingSession(f)
            let original = try Data(contentsOf: url)
            let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
            process.automaticallyStops = false
            f.runtime.confirmKick(request, repository: f.repository)
            if shutdown { f.runtime.stopAll() }
            process.finishStop(shutdown)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(f.factory.processes.count, 1)
        }
    }

    func testAccountFailuresOfferRetryWithoutReplacingSession() throws {
        for failure in [AgentRuntimeFailure.usageLimit, .authenticationRequired] {
            let f = try fixture(), (agent, process, url, _) = try missingSession(f)
            let original = try Data(contentsOf: url)
            process.transition(.failed, failure: failure)
            let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
            XCTAssertEqual(request.failure, failure)
            XCTAssertEqual(process.stops, 0)
            f.runtime.confirmKick(request, repository: f.repository)
            XCTAssertEqual(f.factory.processes.count, 2)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testSafetyStopKickResumesTheSessionOrStartsANewOne() throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode), process = try f.start(agent)
        let url = f.repository.storage(for: agent.id).sessionState(provider: .claudeCode, extendedAccess: false)
        let original = Data("saved session".utf8)
        try original.write(to: url)
        process.transition(.failed, failure: .safetyStop)
        let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
        XCTAssertEqual(request.failure, .safetyStop)
        XCTAssertEqual(process.stops, 0)
        f.runtime.confirmKick(request, repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertEqual(try Data(contentsOf: url), original, "Resume keeps the session")
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)

        let resumed = try XCTUnwrap(f.factory.processes.last)
        resumed.transition(.failed, failure: .safetyStop)
        let again = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
        XCTAssertEqual(again.failure, .safetyStop)
        f.runtime.startNewSession(agent: agent, repository: f.repository)
        XCTAssertEqual(resumed.stops, 1)
        XCTAssertEqual(f.factory.processes.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "New Session drops the session pointer")
        XCTAssertFalse(f.factory.processes.last!.launch.recoverInterruptedWork)
    }

    func testSessionChangedWhileStoppingIsPreservedAndDoesNotEnterSupervision() throws {
        let f = try fixture(), (agent, process, url, _) = try missingSession(f)
        let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
        process.automaticallyStops = false
        f.runtime.confirmKick(request, repository: f.repository)
        let replacement = ACPSessionState(sessionID: UUID().uuidString)
        try replacement.save(to: url)
        process.finishStop(true)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .failed)
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        f.runtime.notify([agent], repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url)), replacement)
        XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository))
        XCTAssertEqual(f.factory.processes.count, 2, "The next Kick must check the current session instead of repeating stale recovery")
        XCTAssertEqual(try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url)), replacement)
    }

    func testKickExplicitlyUnblocksAnInterruptedRecovery() throws {
        let f = try fixture(), (agent, process, url, _) = try missingSession(f)
        var state = ACPSessionState(sessionID: UUID().uuidString)
        state.needsHistoryRecovery = true
        state.recoveryBlocked = true
        try state.save(to: url)
        process.transition(.failed, failure: .recoveryFailed)
        XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository))
        let saved = try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.sessionID, state.sessionID)
        XCTAssertTrue(saved.needsHistoryRecovery)
        XCTAssertFalse(saved.recoveryBlocked)
        XCTAssertEqual(f.factory.processes.count, 2)
    }
    func testKickAfterSignInRestartsHarnessesWithoutSessionRecovery() throws {
        for provider in [HarnessProvider.claudeCode, .codex] {
            let f = try fixture(), agent = try f.agent(harness: provider), process = try f.start(agent)
            process.transition(.failed, failure: .authenticationRequired)
            let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
            f.runtime.confirmKick(request, repository: f.repository)
            XCTAssertEqual(f.factory.processes.count, 2, "\(provider)")
            XCTAssertNotEqual(f.runtime.snapshot(for: agent.id).failure, .recoveryFailed, "\(provider)")

            f.factory.processes.last!.transition(.failed, failure: .recoveryFailed)
            XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository))
            XCTAssertEqual(f.factory.processes.count, 3, "A plain Kick must leave a failed recovery behind for \(provider)")
        }
    }

    func testBotWaitingOnAnAccountFailureIsNotRestartedWhenItsHarnessExits() throws {
        let failures: [AgentRuntimeFailure] = [.authenticationRequired, .usageLimit, .safetyStop, .recoveryFailed, .missingSession("s")]
        for failure in failures {
            let f = try fixture(), agent = try f.agent(harness: .claudeCode), process = try f.start(agent)
            process.transition(.failed, failure: failure)
            process.isAlive = false
            f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
            XCTAssertEqual(process.stops, 0, "\(failure)")
            XCTAssertEqual(f.factory.processes.count, 1, "Restarting cannot fix \(failure)")
            XCTAssertEqual(f.runtime.snapshot(for: agent.id).failure, failure)
        }
    }

    func testSignInIsAnnouncedOnceUntilATurnFinishes() throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode), process = try f.start(agent)
        var announced: [UUID] = []
        f.runtime.onSignInRequired = { announced.append($0) }
        process.transition(.failed, failure: .authenticationRequired)
        XCTAssertEqual(announced, [agent.id])
        // A new message retries: the harness starts, reports ready, then fails the same way.
        process.transition(.starting)
        process.transition(.ready)
        process.transition(.working)
        process.transition(.failed, failure: .authenticationRequired)
        XCTAssertEqual(announced, [agent.id], "Retries without signing in stay quiet")
        process.transition(.working)
        process.transition(.ready)
        process.transition(.failed, failure: .authenticationRequired)
        XCTAssertEqual(announced, [agent.id, agent.id], "A finished turn proves sign-in worked")
    }
    func testBotWaitingForSignInComesBackByItselfOnceItsHarnessIsSignedIn() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode), process = try f.start(agent)
        let url = f.repository.storage(for: agent.id).sessionState(provider: .claudeCode, extendedAccess: false)
        let session = Data("saved session".utf8)
        try session.write(to: url)
        var signedIn: Bool? = false, checks = 0
        f.runtime.checkSignIn = { _ in checks += 1; return signedIn }
        process.transition(.failed, failure: .authenticationRequired)

        f.runtime.reconcile(agents: [agent], repository: f.repository)
        try await f.clock.waitUntil { checks == 1 }
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        await Task.yield()
        XCTAssertEqual(checks, 1, "Checks are spaced out")
        XCTAssertEqual(f.factory.processes.count, 1, "Still signed out: the bot keeps waiting")

        signedIn = true
        f.clock.date += 120
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        try await f.clock.waitUntil { f.factory.processes.count == 2 }
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
        XCTAssertEqual(try Data(contentsOf: url), session, "The session is resumed, not replaced")
        XCTAssertFalse(f.factory.processes.last!.launch.recoverInterruptedWork, "Nothing was interrupted, so no turn is started")
    }

    func testBotWaitingForSignInComesBackAfterItsStatusChanged() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode), process = try f.start(agent)
        f.runtime.checkSignIn = { _ in true }
        process.transition(.failed, failure: .authenticationRequired)
        var updated = agent
        updated.status = "Reviewing PRs"
        f.runtime.reconcile(agents: [updated], repository: f.repository)
        try await f.clock.waitUntil { f.factory.processes.count == 2 }
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }

    func testLoginThatLooksValidButStillFailsIsRetriedOnlyAFewTimes() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode)
        var signedIn: Bool? = true, checks = 0
        f.runtime.checkSignIn = { _ in checks += 1; return signedIn }
        try f.start(agent).transition(.failed, failure: .authenticationRequired)
        for _ in 0..<12 {
            f.clock.date += 60 * 60
            let before = checks
            f.runtime.reconcile(agents: [agent], repository: f.repository)
            try await f.clock.waitUntil { checks == before + 1 }
            await Task.yield()
            f.factory.processes.last!.transition(.failed, failure: .authenticationRequired)
        }
        XCTAssertEqual(f.factory.processes.count, 5, "Four automatic retries, then it waits for a new sign-in")

        signedIn = nil
        f.clock.date += 60 * 60
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        try await f.clock.waitUntil { checks == 13 }
        signedIn = true
        f.clock.date += 60 * 60
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        try await f.clock.waitUntil { checks == 14 }
        await Task.yield()
        XCTAssertEqual(f.factory.processes.count, 5, "A failed check is not a new sign-in")

        signedIn = false
        f.clock.date += 60 * 60
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        try await f.clock.waitUntil { checks == 15 }
        signedIn = true
        f.clock.date += 60 * 60
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        try await f.clock.waitUntil { f.factory.processes.count == 6 }
    }

    /// The host refuses a start on the login that already failed, before any turn, so refusals
    /// are not tries: the bot keeps waiting as "sign-in needed" and still comes back after a sign-in.
    func testStartsRefusedOnTheFailedLoginKeepWaitingAndDoNotUseUpRetries() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode)
        f.runtime.checkSignIn = { _ in true }
        try f.start(agent).transition(.failed, failure: .authenticationRequired)
        f.factory.startRefusedUntil = f.clock.date + 365 * 24 * 60 * 60
        for _ in 0..<8 {
            f.clock.date += 60 * 60
            let before = f.factory.processes.count
            f.runtime.reconcile(agents: [agent], repository: f.repository)
            try await f.clock.waitUntil { f.factory.processes.count == before + 1 }
            XCTAssertEqual(f.runtime.snapshot(for: agent.id).failure, .authenticationRequired)
        }
        f.factory.startRefusedUntil = nil
        f.clock.date += 60 * 60
        f.runtime.reconcile(agents: [agent], repository: f.repository)
        try await f.clock.waitUntil { f.factory.processes.count == 10 }
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }

    /// Steps the clock a minute at a time from now and returns the minutes at which the bot was started again.
    private func restartMinutes(_ f: RuntimeCoordinatorFixture, _ agent: AgentRecord, through last: Int,
                                each minute: (Int) -> Void = { _ in }) async -> [Int] {
        let start = f.clock.date
        var restarts: [Int] = []
        for elapsed in 0...last {
            f.clock.date = start + TimeInterval(elapsed * 60)
            minute(elapsed)
            let before = f.factory.processes.count
            f.runtime.reconcile(agents: [agent], repository: f.repository)
            for _ in 0..<20 { await Task.yield() }
            if f.factory.processes.count > before { restarts.append(elapsed) }
        }
        return restarts
    }

    /// Grok Build and OpenCode refuse a login while they start. Those are real starts on the
    /// login, so they keep the few spaced-out retries and then wait for a new sign-in.
    func testAHarnessRefusingItsLoginWhileStartingIsRetriedOnlyAFewTimes() async throws {
        let f = try fixture(), agent = try f.agent(harness: .grokBuild)
        f.runtime.checkSignIn = { _ in true }
        try f.start(agent).transition(.failed, failure: .authenticationRequired)
        f.factory.startFailure = .authenticationRequired
        let restarts = await restartMinutes(f, agent, through: 3 * 60)
        XCTAssertEqual(restarts, [0, 2, 6, 14], "Retries 2, 4 and 8 minutes apart, then none")
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).failure, .authenticationRequired)
    }

    /// A start the host refused reached no harness: it is asked again when the refusal lapses,
    /// and every ten minutes until then, which notices a new sign-in, never every two.
    func testRefusedStartsAreAskedAgainWhenTheRefusalLapsesAndOtherwiseOnlyEveryTenMinutes() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode)
        f.runtime.checkSignIn = { _ in true }
        try f.start(agent).transition(.failed, failure: .authenticationRequired)
        let lapse = f.clock.date + 25 * 60
        f.factory.startRefusedUntil = lapse
        let restarts = await restartMinutes(f, agent, through: 40) { elapsed in
            if elapsed == 25 { f.factory.startRefusedUntil = nil }
        }
        XCTAssertEqual(restarts, [0, 10, 20, 25])
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }

    /// Where the refusal of the login is noted, the host refuses the starts in between and so spaces
    /// out the real tries; those go on past the few, so the bot does not wait for a person.
    func testABotWhoseRefusedLoginIsNotedKeepsBeingRetried() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode)
        let workspace = f.repository.directory(for: agent)
        let runtime = try WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime", create: true)
        try runtime.writeData(Data("login-key:spent".utf8), named: "auth-seed-claude-code-.credentials.json.sha256")
        try RestrictedHarnessStorage.loginFailed(provider: .claudeCode, workspace: workspace, now: f.clock.date)
        f.runtime.checkSignIn = { _ in true }
        try f.start(agent).transition(.failed, failure: .authenticationRequired)
        f.factory.startFailure = .authenticationRequired
        let restarts = await restartMinutes(f, agent, through: 3 * 60)
        XCTAssertEqual(restarts, [0, 2, 6, 14] + Array(stride(from: 30, through: 3 * 60, by: 16)))
    }

    /// Opening the Kick alert can let a background check start the bot again before Retry Now
    /// is chosen. The bot still waits for sign-in, so Retry Now retries, on the refused login too.
    func testRetryNowForgetsTheRefusedLoginAndRetriesThoughTheBotWasStartedAgainMeanwhile() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode), process = try f.start(agent)
        let workspace = f.repository.directory(for: agent)
        let runtime = try WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime", create: true)
        try runtime.writeData(Data("login-key:spent".utf8), named: "auth-seed-claude-code-.credentials.json.sha256")
        try RestrictedHarnessStorage.loginFailed(provider: .claudeCode, workspace: workspace, now: f.clock.date)
        process.transition(.failed, failure: .authenticationRequired)
        let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
        f.factory.startRefusedUntil = f.clock.date + 5 * 60
        f.runtime.restart(agent: agent, repository: f.repository)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).failure, .authenticationRequired)
        f.factory.startRefusedUntil = nil
        let before = f.factory.processes.count
        f.runtime.confirmKick(request, repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, before + 1, "Retry Now must retry")
        XCTAssertNil(RestrictedHarnessStorage.refusedUntil(provider: .claudeCode, workspace: workspace),
                     "The host must not refuse the retry the person asked for")
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }

    func testMessageToABotWaitingForSignInReachesItsHarness() throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode), process = try f.start(agent)
        process.transition(.failed, failure: .authenticationRequired)
        process.isAlive = false
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        f.runtime.notify([agent], repository: f.repository)
        XCTAssertEqual(process.notifications.count, 1, "Signing in and sending a message is enough to continue")
        XCTAssertEqual(f.factory.processes.count, 1)
    }

    func testStoppedOrRemovedBotIsAnnouncedAgainWhenItsSignInExpires() throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode)
        var announced: [UUID] = []
        f.runtime.onSignInRequired = { announced.append($0) }
        try f.start(agent).transition(.failed, failure: .authenticationRequired)
        f.runtime.stop(agentID: agent.id)
        try f.start(agent).transition(.failed, failure: .authenticationRequired)
        XCTAssertEqual(announced.count, 2, "Stopping forgets the earlier alert")
        f.runtime.refresh(agents: [])
        try f.start(agent).transition(.failed, failure: .authenticationRequired)
        XCTAssertEqual(announced.count, 3, "Removing forgets the earlier alert")
    }
}
