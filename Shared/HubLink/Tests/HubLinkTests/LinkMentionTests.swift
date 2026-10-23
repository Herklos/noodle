import HubLink
import XCTest

/// A mention is the person's name, never an @handle, so the Hub, the Mac and the iPhone agree on what notifies.
final class LinkMentionTests: XCTestCase {
    func testTheFullNameOrTheFirstNameAloneMentions() {
        XCTAssertTrue(LinkMention.mentions("Thanks, Petko Petkov.", name: "Petko Petkov"))
        XCTAssertTrue(LinkMention.mentions("Petko, the build is green.", name: "Petko Petkov"))
        XCTAssertTrue(LinkMention.mentions("Ask Petko's opinion first", name: "Petko Petkov"))
        XCTAssertTrue(LinkMention.mentions("Done,\nPetko\nPetkov", name: "Petko  Petkov"))
        XCTAssertFalse(LinkMention.mentions("Petkov signed it.", name: "Petko Petkov"), "The last name alone is not a mention")
        XCTAssertFalse(LinkMention.mentions("The build is green.", name: "Petko Petkov"))
    }

    func testOnlyWholeWordsMention() {
        XCTAssertTrue(LinkMention.mentions("Ada: done", name: "Ada"))
        XCTAssertTrue(LinkMention.mentions("(ada)", name: "Ada"))
        XCTAssertFalse(LinkMention.mentions("Adam shipped it from Canada.", name: "Ada"))
        XCTAssertFalse(LinkMention.mentions("ada_lovelace and ada2", name: "Ada"))
    }

    func testCaseAndAccentsDoNotMatter() {
        XCTAssertTrue(LinkMention.mentions("zoe, look", name: "Zoë Martin"))
        XCTAssertTrue(LinkMention.mentions("ZOË MARTIN is here", name: "Zoe Martin"))
        XCTAssertTrue(LinkMention.mentions("Merci, jose", name: "José"))
    }

    func testNamesInCodeDoNotMention() {
        XCTAssertFalse(LinkMention.mentions("```\nlet ada = 1\n```", name: "Ada"))
        XCTAssertFalse(LinkMention.mentions("~~~swift\nprint(\"Ada\")\n~~~", name: "Ada"))
        XCTAssertFalse(LinkMention.mentions("Run `ada --help` to see.", name: "Ada"))
        XCTAssertFalse(LinkMention.mentions("Unclosed:\n```\nAda", name: "Ada"))
        XCTAssertTrue(LinkMention.mentions("Ada, run `make` then:\n```\nmake test\n```", name: "Ada"))
        XCTAssertTrue(LinkMention.mentions("```\ncode\n```\nOver to you, Ada.", name: "Ada"))
    }

    func testWithoutANameNothingMentions() {
        XCTAssertFalse(LinkMention.mentions("Anyone there?", name: ""))
        XCTAssertFalse(LinkMention.mentions("Anyone there?", name: "  \n"))
    }

    /// A group keeps the user's level for all groups unless it has its own; a level from a newer app notifies every reply.
    func testAGroupsLevelFallsBackToTheUsersLevel() {
        XCTAssertEqual(LinkNotifications.effective(nil, inGroups: nil), .all)
        XCTAssertEqual(LinkNotifications.effective(nil, inGroups: .mentions), .mentions)
        XCTAssertEqual(LinkNotifications.effective(.default, inGroups: .mentions), .mentions)
        XCTAssertEqual(LinkNotifications.effective(.all, inGroups: .mentions), .all)
        XCTAssertEqual(LinkNotifications.effective(.muted, inGroups: .mentions), .muted)
        XCTAssertEqual(LinkNotifications.effective(.mentions, inGroups: .all), .mentions)
        XCTAssertEqual(LinkNotifications.effective(LinkNotifications(rawValue: "later"), inGroups: .mentions), .all)
        XCTAssertEqual(LinkNotifications.effective(nil, inGroups: LinkNotifications(rawValue: "later")), .all)

        XCTAssertTrue(LinkNotifications.all.notifies("Shipped.", name: "Ada"))
        XCTAssertFalse(LinkNotifications.mentions.notifies("Shipped.", name: "Ada"))
        XCTAssertTrue(LinkNotifications.mentions.notifies("Shipped, Ada.", name: "Ada"))
        XCTAssertFalse(LinkNotifications.muted.notifies("Shipped, Ada.", name: "Ada"), "Muted is silent, even for a mention")
    }
}
