import Foundation
import HubLink
import NoodleBrand

/// A new bot's face, which follows its name until a picture is chosen for it.
struct AutomaticFace {
    /// The face put on the bot; a picture other than this one was chosen.
    private(set) var worn: Data?

    /// `fresh` brings another face even when the one worn still suits the name, as for another generated name.
    mutating func follow(_ draft: inout LinkBotDraft, others: [LinkBot], fresh: Bool = false) {
        guard draft.avatarImageData == worn else { return }
        // Bots on a Hub are listed with their picture's digest, not the picture.
        let digests = Set(others.compactMap { $0.draft.avatarImageDigest ?? $0.draft.avatarImageData.map(LinkPicture.digest) })
        var used = Set(BotFaces.all.map(\.imageData).filter { digests.contains(LinkPicture.digest($0)) })
        if fresh, let worn { used.insert(worn) }
        let presentation = BotNameGenerator.presentation(of: draft.name) ?? nil
        worn = BotFaces.fitting(presentation, current: fresh ? nil : worn, avoiding: used)
        draft.avatarImageData = worn
    }
}
