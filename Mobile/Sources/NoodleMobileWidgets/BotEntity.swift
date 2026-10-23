import AppIntents
import Foundation

// Built into the widgets, for their settings and the Agent control, and into the app, for its Shortcuts actions.

/// A bot the app left on the shelf, as a widget's settings offer it.
struct BotEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"
    static let defaultQuery = BotQuery()

    let id: String
    let name: String
    /// Its Hub's name, when bots of several Hubs are offered.
    let hubName: String?
    let image: Data?

    init(_ bot: WidgetBot, in shelf: WidgetShelf) {
        id = bot.id
        name = bot.name
        hubName = shelf.namesHubs ? bot.hubName : nil
        image = bot.image
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: hubName.map { "\($0)" },
                              image: image.map { DisplayRepresentation.Image(data: $0) })
    }
}

/// The bots of every Hub, in All's order. The first is chosen until the person picks another.
struct BotQuery: EntityStringQuery {
    func entities(for identifiers: [BotEntity.ID]) async throws -> [BotEntity] {
        let shelf = Shelf.load()
        return identifiers.compactMap(shelf.bot).map { BotEntity($0, in: shelf) }
    }

    func entities(matching string: String) async throws -> [BotEntity] {
        let shelf = Shelf.load()
        return shelf.bots.filter { $0.name.localizedStandardContains(string) }.map { BotEntity($0, in: shelf) }
    }

    func suggestedEntities() async throws -> [BotEntity] {
        let shelf = Shelf.load()
        return shelf.bots.map { BotEntity($0, in: shelf) }
    }

    func defaultResult() async -> BotEntity? {
        let shelf = Shelf.load()
        return shelf.bots.first.map { BotEntity($0, in: shelf) }
    }
}

/// What the app last left; empty before it has run with a Hub.
enum Shelf {
    static func load() -> WidgetShelf { BotWidgetShelf.configured()?.load() ?? WidgetShelf() }

    /// The bot as the app last left it, so a call goes only to one that takes calls.
    static func bot(_ bot: BotEntity) throws -> WidgetBot {
        guard let shelved = load().bot(bot.id) else { throw AgentGone() }
        return shelved
    }
}

struct AgentGone: LocalizedError {
    var errorDescription: String? { "That agent is no longer available. Open Noodle to see your agents." }
}
