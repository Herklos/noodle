import Foundation
import XCTest
import NoodleBrand
@testable import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class StarterTeamTests: XCTestCase {
    func testFirstRunSetsUpATeamAndTheirGroupOnTheAccountJustSignedIn() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        let team = f.store.createStarterTeam(on: .codex, style: .real)
        XCTAssertEqual(team.count, 3, f.store.errorMessage ?? "")
        XCTAssertEqual(Set(team.compactMap(\.harnessIdentifier)), [HarnessProvider.codex.rawValue])
        let names = team.map(\.displayName)
        XCTAssertEqual(Set(names).count, 3, "Each has a name of its own.")
        XCTAssertTrue(Set(names).isDisjoint(with: ["Ada", "Grace"]), "Nor one a bot already has.")
        XCTAssertEqual(Set(team.compactMap(\.avatarColorIndex)).count, 3)
        for bot in team { XCTAssertFalse(bot.publicDescription?.isEmpty ?? true, "\(bot.displayName) says what it does.") }
        let group = try XCTUnwrap(f.store.selectedConversation, "The group opens.")
        XCTAssertEqual(group.kind, .group)
        XCTAssertEqual(group.displayName, StarterTeam.groupName)
        XCTAssertEqual(Set(group.participantIDs), Set(team.map(\.id)))
    }

    func testTheWelcomeAgainOnlySetsUpTheAccountForSomeoneWithBots() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        let before = f.store.agents
        XCTAssertNil(f.store.createStarterTeamIfFirst(on: .codex, style: .real), "Bots already exist, so none are made.")
        XCTAssertEqual(f.store.agents, before)
    }

    func testTheFirstSetupMakesTheTeam() throws {
        let runtime = try RuntimeCoordinatorFixture()
        let store = NoodleStore(repository: runtime.repository, runtime: runtime.runtime, connectsServices: false)
        defer { store.stopMonitoring(); runtime.cleanUp() }
        XCTAssertEqual(store.createStarterTeamIfFirst(on: .codex, style: .real)?.count, 3, store.errorMessage ?? "")
    }

    func testEachHasARoleAndAShortBackstory() {
        XCTAssertEqual(StarterTeam.members.map(\.role), ["Personal Assistant", "Full-Stack Developer", "Researcher"])
        for member in StarterTeam.members {
            XCTAssertFalse(member.publicDescription.contains(":"), "A plain sentence, not a label: \(member.role)")
            let sentences = member.backstory.split(separator: ".", omittingEmptySubsequences: true)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            XCTAssertTrue((2...3).contains(sentences.count), "\(member.role): \(sentences.count) sentences")
        }
    }

    func testContinuingFromTheTeamWakesThemToIntroduceThemselvesInTheirGroup() async throws {
        let runtime = try RuntimeCoordinatorFixture()
        let store = NoodleStore(repository: runtime.repository, runtime: runtime.runtime, connectsServices: false)
        defer { store.stopMonitoring(); runtime.cleanUp() }
        let team = try XCTUnwrap(store.createStarterTeamIfFirst(on: .codex, style: .real))
        let group = try XCTUnwrap(store.selectedConversation)
        await runtime.runtime.settleWakes()
        for bot in team { XCTAssertEqual(try runtime.repository.listWakes(agentID: bot.id).due, [], "Not before Continue.") }
        store.introduceStarterTeam(in: group.id)
        await runtime.runtime.settleWakes()
        for bot in team {
            XCTAssertEqual(try runtime.repository.listWakes(agentID: bot.id).due.map(\.note), [AgentWake.introductionNote(in: group.id)])
        }
        XCTAssertTrue(store.messages(for: group).isEmpty, "Nothing is sent in the person's name.")
        XCTAssertEqual(store.selectedConversationID, group.id)
    }
}
