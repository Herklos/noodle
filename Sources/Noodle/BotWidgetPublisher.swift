import AppKit
import HubLink
import NoodleCore
import NoodleRuntimeSettings
import SwiftUI
import WidgetKit

/// Keeps the desktop widgets' bots current. Widgets reload only when what they show changes.
@MainActor
final class BotWidgetPublisher {
    private let shelf = BotWidgetShelf.configured()
    private var published: [WidgetBot]?
    private struct PictureSource: Equatable { let symbol: String?, colour: Int, image: Data? }
    /// Drawn once per avatar, and small, for widgets have a small image budget.
    private var pictures: [UUID: (source: PictureSource, picture: Data?)] = [:]
    private var lastReload = Date.distantPast
    private var pendingReload: Task<Void, Never>?

    func publish(_ bots: [(bot: WidgetBot, agent: AgentRecord)]) {
        guard let shelf else { return }
        // Once at launch whatever changed, so widgets drawn by an earlier version of Noodle redraw.
        let launching = published == nil
        let previous = published ?? shelf.load()
        let bots = WidgetBots.settle(bots.map { withPicture($0.bot, agent: $0.agent) }, previous: previous, now: Date())
        published = bots
        guard bots != previous || launching else { return }
        do {
            if try shelf.save(bots) || launching { reloadWidgets() }
        } catch { NSLog("Noodle could not update its widgets: %@", error.localizedDescription) }
    }

    /// At most one reload every few seconds, as the system limits how often a widget redraws.
    private func reloadWidgets() {
        guard pendingReload == nil else { return }
        let wait = max(0, 5 - Date().timeIntervalSince(lastReload))
        pendingReload = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            WidgetCenter.shared.reloadAllTimelines()
            self?.lastReload = Date()
            self?.pendingReload = nil
        }
    }

    /// The bot's avatar as the app draws it, for a widget can only show a finished picture faithfully.
    private func withPicture(_ bot: WidgetBot, agent: AgentRecord) -> WidgetBot {
        let source = PictureSource(symbol: agent.avatarSymbolName, colour: agent.avatarColorIndex ?? agent.accentSeed,
                                   image: agent.avatarImageData)
        var bot = bot
        if let cached = pictures[bot.id], cached.source == source {
            bot.image = cached.picture
        } else {
            let renderer = ImageRenderer(content: BotAvatar(agent: agent, size: 80, showsShadow: false))
            renderer.scale = 2
            bot.image = renderer.nsImage.flatMap { $0.tiffRepresentation }.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
            pictures[bot.id] = (source, bot.image)
        }
        return bot
    }
}

extension NoodleStore {
    /// Every bot as All lists it in the sidebar, with whether it is working.
    var widgetBots: [(bot: WidgetBot, agent: AgentRecord)] {
        let bots = conversations.compactMap { conversation -> (bot: WidgetBot, agent: AgentRecord)? in
            guard conversation.kind == .direct, !isArchived(conversation),
                  let agent = participants(for: conversation).first else { return nil }
            // A bot on a Noodle Hub runs there; the Hub says when it works.
            let phase = hubMirror(forAgent: agent.id).map { $0.isConnected ? $0.phase(ofAgent: agent.id) : nil }
                ?? runtime.snapshot(for: agent.id).phase
            return (WidgetBot(id: agent.id, conversationID: conversation.id, name: agent.displayName,
                              symbol: agent.avatarSymbolName, colour: agent.avatarColorIndex ?? agent.accentSeed,
                              status: WidgetBots.statusLine(status: agent.status, messages: messages(for: conversation),
                                                            agentID: agent.id) {
                                  MarkdownPlainText.convert(MessageSegment.previewText($0))
                              },
                              isWorking: phase == .working,
                              finishedAt: runtime.lastActiveDates[agent.id]), agent)
        }
        let ordered = WidgetBots.launcher(bots.map(\.bot), pinnedConversationIDs: pinnedConversationIDs).map(\.id)
        return ordered.compactMap { id in bots.first { $0.bot.id == id } }
    }

    /// A widget's link to a bot. Returns false for any other link.
    func openWidgetLink(_ url: URL) -> Bool {
        guard let conversationID = WidgetBots.conversationID(fromLink: url) else { return false }
        #if DEBUG
        NSLog("WIDGET-PROBE %@://conversation/%@", url.scheme ?? "noodle", conversationID.uuidString.lowercased())
        #endif
        openNotification(conversationID: conversationID, messageID: nil)
        // A widget opens the link without bringing Noodle forward.
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
