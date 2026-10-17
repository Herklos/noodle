import HubLink
import SwiftUI
import WidgetKit

/// Keeps the Home Screen widgets' bots current while the app runs. Widgets reload only when what they show changes.
@MainActor final class BotWidgetPublisher {
    static let shared = BotWidgetPublisher(shelf: .configured())

    /// What the widgets show, before the pictures are drawn, so it is cheap to compare whenever the list changes.
    struct Source: Equatable {
        struct Bot: Equatable {
            var hub: String
            var hubName: String
            var conversationID: UUID
            var face: BotFace

            var id: String { WidgetBot.id(hub: hub, conversationID: conversationID) }
        }

        var bots: [Bot] = []
        var spaces: [WidgetSpace] = []
    }

    /// The bots as the list shows them: All in its order, each Hub's space with the Hub's pins, then the spaces the
    /// person made. Groups and archived bots are left out.
    static func source(chats: [HubChats], spaces: [CustomSpace]) -> Source {
        func bots(_ threads: [(HubChats, HubThread)]) -> [Source.Bot] {
            threads.compactMap { hub, thread in
                thread.bot.map { Source.Bot(hub: CurrentHub.space(of: hub.pairing), hubName: hub.pairing.hubName,
                                            conversationID: $0.conversationID, face: BotFace($0)) }
            }
        }
        let all = bots(HubChats.sorted(chats.flatMap { hub in hub.listedThreads.map { (hub, $0) } }))
        let hubs = chats.map { hub in
            WidgetSpace(id: CurrentHub.space(of: hub.pairing), name: hub.pairing.hubName,
                        bots: bots(HubChats.sorted(hub.listedThreads.map { (hub, $0) }, onHub: true)).map(\.id))
        }
        let made = spaces.map { space in
            WidgetSpace(id: space.id.uuidString, name: space.name, bots: bots(HubChats.threads(in: space, of: chats)).map(\.id))
        }
        return Source(bots: all, spaces: hubs + made)
    }

    /// Big enough for a small widget's picture.
    static let pictureSize: CGFloat = 64

    private let shelf: BotWidgetShelf?
    private var published: Source?
    /// Drawn once per avatar, as the widgets' image budget is small.
    private var pictures: [String: (face: BotFace, png: Data?)] = [:]
    private var lastReload = Date.distantPast
    private var pendingReload: Task<Void, Never>?

    init(shelf: BotWidgetShelf?) { self.shelf = shelf }

    func publish(_ source: Source) {
        guard let shelf, source != published else { return }
        // Once a launch whatever changed, so widgets drawn by an earlier version redraw.
        let launching = published == nil
        published = source
        let bots = source.bots.map { bot in
            WidgetBot(hub: bot.hub, conversationID: bot.conversationID, name: bot.face.name, hubName: bot.hubName,
                      image: picture(of: bot))
        }
        let shown = Set(bots.map(\.id))
        pictures = pictures.filter { shown.contains($0.key) }
        do {
            if try shelf.save(WidgetShelf(bots: bots, spaces: source.spaces)) || launching { reloadWidgets() }
        } catch {
            ReplyNotification.log.error("The widgets' bots could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The avatar as the app draws it, for a widget can only show a finished picture faithfully.
    private func picture(of bot: Source.Bot) -> Data? {
        if let kept = pictures[bot.id], kept.face == bot.face { return kept.png }
        let renderer = ImageRenderer(content: AgentAvatar(face: bot.face, size: Self.pictureSize))
        renderer.scale = 3
        let png = renderer.uiImage?.pngData()
        pictures[bot.id] = (bot.face, png)
        return png
    }

    /// At most one reload every few seconds, as iOS limits how often a widget redraws.
    private func reloadWidgets() {
        guard pendingReload == nil else { return }
        let wait = max(0, 5 - Date().timeIntervalSince(lastReload))
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            WidgetCenter.shared.reloadAllTimelines()
            self?.lastReload = Date()
            self?.pendingReload = nil
        }
    }
}
