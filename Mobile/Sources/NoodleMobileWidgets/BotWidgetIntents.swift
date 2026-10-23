import AppIntents
import WidgetKit

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

    /// Only bots that take calls have the button. A summary's condition can test only whether a bot is chosen, not
    /// what the bot can do, so the switch shows for every chosen bot.
    @Parameter(title: "Show Call Button", default: true)
    var showCallButton: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$bot, .hasAnyValue) {
            Summary {
                \.$bot
                \.$showCallButton
            }
        } otherwise: {
            Summary {
                \.$bot
            }
        }
    }

    init() {}
}

struct BotsWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Bots"
    static let description = IntentDescription("Choose the space whose bots to show.")

    @Parameter(title: "Space")
    var space: SpaceEntity?

    init() {}
}
