import Foundation

/// A bot as the Home Screen widgets show it. The widget extension sees this and nothing else.
struct WidgetBot: Identifiable, Codable, Hashable, Sendable {
    /// Its Hub's key, as spaces name the Hub, so a widget keeps its bot when the Hub is left and joined again.
    var hub: String
    var conversationID: UUID
    var name: String
    var hubName: String
    /// The avatar as the app draws it, as PNG.
    var image: Data?
    /// Whether it takes voice calls, as the chat's Call button shows, so its widget offers a call.
    var callable = false

    /// What iOS keeps for a widget showing this bot.
    var id: String { Self.id(hub: hub, conversationID: conversationID) }

    static func id(hub: String, conversationID: UUID) -> String { "\(hub)/\(conversationID.uuidString)" }

    private enum CodingKeys: String, CodingKey {
        case hub, conversationID, name, hubName, image, callable
    }
}

extension WidgetBot {
    /// Bots an earlier version left have no `callable` and offer no call until the app runs again.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(hub: try container.decode(String.self, forKey: .hub),
                  conversationID: try container.decode(UUID.self, forKey: .conversationID),
                  name: try container.decode(String.self, forKey: .name),
                  hubName: try container.decode(String.self, forKey: .hubName),
                  image: try container.decodeIfPresent(Data.self, forKey: .image),
                  callable: try container.decodeIfPresent(Bool.self, forKey: .callable) ?? false)
    }

    /// Whether its Bot widget shows the call button: only while it takes calls, and the widget's Show Call Button,
    /// on until the person turns it off, is on.
    func showsCallButton(setting: Bool = true) -> Bool { callable && setting }
}

/// A space a widget can show: a Hub's own or one the person made, with its bots in the list's order.
struct WidgetSpace: Identifiable, Codable, Hashable, Sendable {
    /// All, which holds every bot. No Hub's key or space's ID is ever this.
    static let allID = "all"

    /// A Hub's key, or the ID of a space the person made, as the app's space menu names them.
    var id: String
    var name: String
    /// `WidgetBot.id`s.
    var bots: [String]
}

/// What the app leaves for its widgets: every bot in All's order, and the spaces.
struct WidgetShelf: Codable, Equatable, Sendable {
    var bots: [WidgetBot] = []
    var spaces: [WidgetSpace] = []

    func bot(_ id: String) -> WidgetBot? { bots.first { $0.id == id } }

    /// A space's bots in its order, every bot for All, and nil for a space no longer there.
    func bots(in space: String) -> [WidgetBot]? {
        if space == WidgetSpace.allID { return bots }
        guard let space = spaces.first(where: { $0.id == space }) else { return nil }
        let byID = Dictionary(bots.map { ($0.id, $0) }) { first, _ in first }
        return space.bots.compactMap { byID[$0] }
    }

    /// Bots of several Hubs are told apart by their Hub's name.
    var namesHubs: Bool { Set(bots.map(\.hub)).count > 1 }
}

/// A widget's link to a bot's conversation: noodle://conversation/ID, as on the Mac, with its Hub's key.
/// Its call button's is noodle://call/ID, which opens the conversation and calls the bot.
struct WidgetLink: Equatable, Sendable {
    private static let host = "conversation"
    private static let callHost = "call"
    /// What a Hub's key, which is base64, keeps unescaped in the link.
    private static let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    let hub: String
    let conversationID: UUID
    /// Whether it calls the bot as well.
    let call: Bool

    init(hub: String, conversationID: UUID, call: Bool = false) {
        self.hub = hub
        self.conversationID = conversationID
        self.call = call
    }

    init(_ bot: WidgetBot, call: Bool = false) { self.init(hub: bot.hub, conversationID: bot.conversationID, call: call) }

    /// Call Agent's link: a call to a bot that takes calls, otherwise its chat.
    init(calling bot: WidgetBot) { self.init(bot, call: bot.callable) }

    /// Nil for any other link, such as a Hub's invitation.
    init?(url: URL) {
        guard let host = url.host, host == Self.host || host == Self.callHost, url.pathComponents.count == 2,
              let conversationID = UUID(uuidString: url.pathComponents[1]),
              let hub = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "hub" })?.value,
              !hub.isEmpty else { return nil }
        self.init(hub: hub, conversationID: conversationID, call: host == Self.callHost)
    }

    var url: URL {
        let hub = hub.addingPercentEncoding(withAllowedCharacters: Self.plain) ?? hub
        return URL(string: "noodle://\(call ? Self.callHost : Self.host)/\(conversationID.uuidString.lowercased())?hub=\(hub)")!
    }
}

/// Where the app leaves its widgets' bots, in the group it shares with its extensions.
struct BotWidgetShelf: Sendable {
    let fileURL: URL

    init(rootURL: URL) { fileURL = rootURL.appendingPathComponent("bots.json") }

    static func configured(bundle: Bundle = .main) -> BotWidgetShelf? {
        guard let identifier = bundle.object(forInfoDictionaryKey: "NoodleAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else { return nil }
        return BotWidgetShelf(rootURL: container.appendingPathComponent("Library/Application Support/Widgets", isDirectory: true))
    }

    func load() -> WidgetShelf {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(WidgetShelf.self, from: $0) } ?? WidgetShelf()
    }

    /// Returns whether anything changed, so widgets reload only then.
    @discardableResult
    func save(_ shelf: WidgetShelf) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(shelf)
        guard (try? Data(contentsOf: fileURL)) != data else { return false }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return true
    }
}
