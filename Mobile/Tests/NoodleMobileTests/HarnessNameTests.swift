import Foundation
import HubLink
@testable import NoodleMobile
import Testing

/// A chosen harness reads on one line, with its profile after the provider.
struct HarnessNameTests {
    @Test func ownLoginIsTheProvider() {
        #expect(LinkHarness(provider: "codex", providerName: "Codex", profileName: nil).chosenName == "Codex")
    }

    @Test func profileFollowsTheProvider() {
        let harness = LinkHarness(provider: "codex", providerName: "Codex", profile: UUID(), profileName: "ada@example.com")
        #expect(harness.chosenName == "Codex · ada@example.com")
    }
}

/// The bot editor lists harnesses under the Hub that lends them, as the Mac does.
struct HubHarnessesTests {
    private let profile = UUID()
    private var home: HubHarnesses {
        HubHarnesses(hub: "home", name: "Home Hub", harnesses: [
            LinkHarness(provider: "codex", providerName: "Codex", profileName: nil),
            LinkHarness(provider: "codex", providerName: "Codex", profile: profile, profileName: "ada@example.com"),
        ])
    }
    private var work: HubHarnesses {
        HubHarnesses(hub: "work", name: "Work Hub", harnesses: [
            LinkHarness(provider: "claude", providerName: "Claude Code", profileName: nil),
        ])
    }

    @Test func newBotChoosesOnEveryHubThatLends() {
        let empty = HubHarnesses(hub: "empty", name: "Empty Hub", harnesses: [])
        let choices = HubHarnesses.choices([home, empty, work], botOn: "home", existing: nil)
        #expect(choices.map(\.name) == ["Home Hub", "Work Hub"])
        #expect(choices.first?.harnesses.map(\.profileName) == [nil, "ada@example.com"])
    }

    @Test func existingBotKeepsToItsOwnHub() {
        let bot = LinkBotDraft(name: "Ada", provider: "claude")
        #expect(HubHarnesses.choices([home, work], botOn: "work", existing: bot) == [work])
    }

    @Test func existingBotKeepsAHarnessNoLongerLent() {
        let bot = LinkBotDraft(name: "Ada", provider: "codex", profile: UUID())
        let choices = HubHarnesses.choices([home, work], botOn: "home", existing: bot)
        #expect(choices.map(\.hub) == ["home"])
        #expect(choices.first?.harnesses.count == 3)
        #expect(choices.first?.harnesses.first?.profile == bot.profile)
        #expect(choices.first?.harnesses.first?.providerName == "Codex")
    }
}
