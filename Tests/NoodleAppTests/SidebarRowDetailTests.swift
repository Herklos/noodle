import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class SidebarRowDetailTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }

    func testLatestMessageIsTheDefault() {
        XCTAssertEqual(SidebarRowDetail.standard, .latestMessage)
        XCTAssertEqual(SidebarRowDetail.allCases.map(\.name), ["Latest Message", "Description"])
    }

    func testDescriptionShowsWhatEachBotAndGroupIsFor() throws {
        let f = try fixture()
        _ = try f.repository.updateAgent(f.a, displayName: f.a.displayName, harnessIdentifier: f.a.harnessIdentifier,
                                         modelIdentifier: nil, reasoningEffort: nil, publicDescription: "Plans the release")
        f.store.reload()
        let group = try f.group(description: "Quarterly planning")
        _ = try f.repository.sendUserMessage(conversationID: f.directA.id, body: "A **violet** notebook")
        _ = try f.repository.sendUserMessage(conversationID: f.directB.id, body: "Hello Grace")
        _ = try f.repository.sendUserMessage(conversationID: group.id, body: "Hello team")
        f.store.refreshTranscripts()

        XCTAssertEqual(f.store.sidebarDetail(for: f.directA, showing: .latestMessage), "A violet notebook")
        XCTAssertEqual(f.store.sidebarDetail(for: group, showing: .latestMessage), "Hello team")

        XCTAssertEqual(f.store.sidebarDetail(for: f.directA, showing: .description), "Plans the release")
        XCTAssertEqual(f.store.sidebarDetail(for: group, showing: .description), "Quarterly planning")
        XCTAssertEqual(f.store.sidebarDetail(for: f.directB, showing: .description), "Hello Grace",
                       "A bot with no description keeps its latest message")
    }
}
