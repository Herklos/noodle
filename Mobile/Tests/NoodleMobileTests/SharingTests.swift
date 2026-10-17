import Foundation
import HubLink
import Intents
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import NoodleMobile

@MainActor @Suite(.timeLimit(.minutes(1))) struct SharingTests {
    /// iOS hands back what it was given for a suggested conversation; the Hub's folder and the
    /// conversation come back out of it, and anything else is no conversation.
    @Test func aSuggestedConversationIsFoundAgainByItsIdentifier() {
        let key = ShareTarget.Key(hub: "1F4D7C2A-0000-4000-8000-000000000001", conversation: UUID())
        #expect(ShareTarget.Key(identifier: key.identifier) == key)
        #expect(ShareTarget.Key(identifier: "no conversation") == nil)
        #expect(ShareTarget.Key(identifier: "hub/not-a-uuid") == nil)
    }

    /// A screenshot comes as a picture file, a page as its link and a selection as its words: the files
    /// are attached, in the order shared, and the rest becomes the message.
    @Test func sharedItemsBecomeFilesAndWords() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let screenshot = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        screenshot.suggestedName = "Screenshot"
        let page = NSItemProvider(object: URL(string: "https://usenoodle.app")! as NSURL)
        let words = NSItemProvider(object: "Have a look" as NSString)

        let shared = await SharedItems.load([screenshot, page, words])

        #expect(shared.files.map(\.filename) == ["Screenshot.png"])
        #expect(shared.files.first?.mediaType == "image/png")
        let file = try #require(shared.files.first)
        #expect(try Data(contentsOf: file.url) == png)
        #expect(shared.text == "https://usenoodle.app\nHave a look")
    }

    /// The share sheet shows a bot by its name and picture, and a group by its own name over its bots,
    /// and either opens Noodle's share sheet at that conversation.
    @Test func aSuggestionNamesTheBotOrTheGroup() throws {
        let scout = BotFace(LinkBotDraft(name: "Scout", provider: "claude"), id: UUID())
        let quill = BotFace(LinkBotDraft(name: "Quill", provider: "codex"), id: UUID())
        let bot = ShareTarget(key: ShareTarget.Key(hub: "hub", conversation: UUID()), name: "Scout", hubName: "Studio",
                              isGroup: false, faces: [scout])
        let group = ShareTarget(key: ShareTarget.Key(hub: "hub", conversation: UUID()), name: "House", hubName: "Studio",
                                isGroup: true, faces: [scout, quill])

        let toBot = ConversationSuggestions.intent(sentTo: bot)
        #expect(toBot.conversationIdentifier == bot.key.identifier)
        #expect(toBot.recipients?.map(\.displayName) == ["Scout"])
        #expect(toBot.speakableGroupName == nil)
        #expect(toBot.recipients?.first?.image != nil)

        let toGroup = ConversationSuggestions.intent(sentTo: group)
        #expect(toGroup.conversationIdentifier == group.key.identifier)
        #expect(toGroup.speakableGroupName?.spokenPhrase == "House")
        #expect(toGroup.recipients?.map(\.displayName) == ["Scout", "Quill"])
        #expect(toGroup.image(forParameterNamed: \INSendMessageIntent.speakableGroupName) != nil)

        // A reply comes from its bot, so the notification shows that bot's picture.
        let reply = ConversationSuggestions.intent(from: quill, in: group, saying: "Done")
        #expect(reply.sender?.displayName == "Quill")
        #expect(reply.content == "Done")
        #expect(reply.conversationIdentifier == group.key.identifier)
    }

    /// iOS cuts a suggested group's picture to a circle, so every bot, ring included, stays inside it.
    @Test func aSuggestedGroupKeepsItsBotsInsideTheCircle() {
        for count in 1...3 {
            for index in 0..<count {
                let offset = SuggestedGroupAvatar.offset(index, of: count, size: 1)
                let reach = (offset.width * offset.width + offset.height * offset.height).squareRoot()
                    + SuggestedGroupAvatar.scale(count) / 2 + SuggestedGroupAvatar.border / 2
                #expect(reach <= 0.5, "bot \(index + 1) of \(count) reaches \(reach)")
            }
        }
    }
}
