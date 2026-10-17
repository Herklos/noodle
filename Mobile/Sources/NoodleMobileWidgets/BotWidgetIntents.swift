import AppIntents
import WidgetKit

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

/// All, a Hub's own space, or one the person made, as the app's space menu lists them.
struct SpaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Space"
    static let defaultQuery = SpaceQuery()
    static let all = SpaceEntity(id: WidgetSpace.allID, name: "All")

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// All comes first and is chosen until the person picks a space.
struct SpaceQuery: EntityQuery {
    func entities(for identifiers: [SpaceEntity.ID]) async throws -> [SpaceEntity] {
        let spaces = try await suggestedEntities()
        return identifiers.compactMap { id in spaces.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [SpaceEntity] {
        [.all] + Shelf.load().spaces.map { SpaceEntity(id: $0.id, name: $0.name) }
    }

    func defaultResult() async -> SpaceEntity? { .all }
}

struct BotWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Bot"
    static let description = IntentDescription("Choose the bot to open.")

    @Parameter(title: "Bot")
    var bot: BotEntity?

    init() {}
}

struct BotsWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Bots"
    static let description = IntentDescription("Choose the space whose bots to show.")

    @Parameter(title: "Space")
    var space: SpaceEntity?

    init() {}
}

/// What the app last left; empty before it has run with a Hub.
enum Shelf {
    static func load() -> WidgetShelf { BotWidgetShelf.configured()?.load() ?? WidgetShelf() }
}
