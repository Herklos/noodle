import Foundation
import HubLink
import NoodleBrand
@testable import NoodleMobile
import Testing

@Suite struct AutomaticFaceTests {
    private func presentation(_ data: Data?) -> BotFacePresentation? {
        data.flatMap(BotFaces.face(for:))?.presentation
    }

    @Test func aNewBotsFaceFollowsItsNameUntilAPictureIsChosen() {
        var face = AutomaticFace()
        var draft = LinkBotDraft(name: "Oscar", provider: "codex")
        face.follow(&draft, others: [])
        let oscar = draft.avatarImageData
        #expect(presentation(oscar) == .masculine)

        // Renaming keeps a face that still suits the name, and changes one that does not.
        draft.name = "Owen"; face.follow(&draft, others: [])
        #expect(draft.avatarImageData == oscar)
        draft.name = "Nora"; face.follow(&draft, others: [])
        #expect(presentation(draft.avatarImageData) == .feminine)

        // Another generated name brings another face, even one that would still fit.
        let nora = draft.avatarImageData
        draft.name = "Mia"; face.follow(&draft, others: [], fresh: true)
        #expect(presentation(draft.avatarImageData) == .feminine)
        #expect(draft.avatarImageData != nora)

        // A picture chosen in the editor, symbol included, stays.
        draft.removePicture()
        draft.name = "Oscar"; face.follow(&draft, others: [])
        #expect(draft.avatarImageData == nil)
    }

    @Test func facesOtherBotsWearAreLeftForLast() {
        let men = BotFaces.all.filter { $0.presentation == .masculine }.map(\.imageData)
        let others = men.dropFirst().map { data in
            var draft = LinkBotDraft(name: "Leo", provider: "codex")
            // As the Hub lists them: the digest of the picture, without the picture.
            draft.avatarImageDigest = LinkPicture.digest(data)
            return LinkBot(id: UUID(), conversationID: UUID(), draft: draft, createdAt: Date())
        }
        var face = AutomaticFace()
        var draft = LinkBotDraft(name: "Oscar", provider: "codex")
        face.follow(&draft, others: others)
        #expect(draft.avatarImageData == men[0])
    }
}
