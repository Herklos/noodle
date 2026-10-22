import AppIntents
import SwiftUI
import WidgetKit

// Actions for Shortcuts, Siri, Control Center and the Action Button, named as the Mac's Send to Agent is. Each opens
// the app by the link a widget uses, so the app does the calling; a Shortcut may leave the bot to be picked when it runs.

/// Calls a bot, opening its chat; one that takes no calls just has its chat opened.
struct CallAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Call Agent"
    static let description = IntentDescription("Call a Noodle agent. If it can't take calls, your chat with it opens instead.",
                                               searchKeywords: ["Call Bot", "Call a Bot", "Bot"])

    @Parameter(title: "Agent", requestValueDialog: "Which agent should Noodle call?")
    var bot: BotEntity?

    init() {}

    init(bot: BotEntity?) { self.bot = bot }

    static var parameterSummary: some ParameterSummary { Summary("Call \(\.$bot)") }

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let bot else { throw $bot.needsValueError() }
        return .result(opensIntent: OpenURLIntent(WidgetLink(calling: try AgentIntents.shelved(bot)).url))
    }
}

/// Opens the chat with a bot.
struct OpenAgentChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat with Agent"
    static let description = IntentDescription("Open your chat with a Noodle agent.",
                                               searchKeywords: ["Open Chat with Bot", "Chat with Bot", "Bot"])

    @Parameter(title: "Agent", requestValueDialog: "Which agent's chat should Noodle open?")
    var bot: BotEntity?

    init() {}

    init(bot: BotEntity?) { self.bot = bot }

    static var parameterSummary: some ParameterSummary { Summary("Open chat with \(\.$bot)") }

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let bot else { throw $bot.needsValueError() }
        return .result(opensIntent: OpenURLIntent(WidgetLink(try AgentIntents.shelved(bot)).url))
    }
}

private enum AgentIntents {
    /// The bot as the app last left it, so a call goes only to one that takes calls.
    static func shelved(_ bot: BotEntity) throws -> WidgetBot {
        guard let shelved = Shelf.load().bot(bot.id) else { throw AgentIntentError.gone }
        return shelved
    }
}

private enum AgentIntentError: LocalizedError {
    case gone

    var errorDescription: String? { "That agent is no longer available. Open Noodle to see your agents." }
}

// MARK: - Control

enum AgentAction: String, AppEnum {
    case call, chat

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Action"
    static let caseDisplayRepresentations: [AgentAction: DisplayRepresentation] = [
        .call: DisplayRepresentation(title: "Call", image: .init(systemName: "phone.fill")),
        .chat: DisplayRepresentation(title: "Open Chat", image: .init(systemName: "bubble.left.fill")),
    ]
}

/// What the person picks when adding the control: the bot, and whether to call it or open its chat.
struct AgentControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Agent"
    static let description = IntentDescription("Choose the agent, and whether to call it or open your chat with it.")

    @Parameter(title: "Agent")
    var bot: BotEntity?

    @Parameter(title: "Action", default: .call)
    var action: AgentAction

    init() {}
}

/// What the control does when pressed, as it was set up. Shortcuts offer Call Agent and Open Chat with Agent instead.
struct AgentControlAction: AppIntent {
    static let title: LocalizedStringResource = "Call or Open Chat with Agent"
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Agent")
    var bot: BotEntity?

    @Parameter(title: "Action", default: .call)
    var action: AgentAction

    init() {}

    init(bot: BotEntity?, action: AgentAction) {
        self.bot = bot
        self.action = action
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let bot else { throw $bot.needsValueError() }
        let shelved = try AgentIntents.shelved(bot)
        return .result(opensIntent: OpenURLIntent((action == .call ? WidgetLink(calling: shelved) : WidgetLink(shelved)).url))
    }
}

/// A Control Center and Action Button control for one bot. One that takes no calls has its chat opened, and shows so.
struct AgentControl: ControlWidget {
    struct Shown {
        var name: String?
        var action: AgentAction
        var bot: BotEntity?
        /// Whether pressing it calls: Call chosen, and the bot takes calls.
        var calls: Bool
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: AgentControlIntent) -> Shown {
            Shown(name: configuration.bot?.name, action: configuration.action, bot: configuration.bot,
                  calls: configuration.action == .call)
        }

        func currentValue(configuration: AgentControlIntent) async throws -> Shown {
            let shelved = configuration.bot.flatMap { Shelf.load().bot($0.id) }
            return Shown(name: shelved?.name ?? configuration.bot?.name, action: configuration.action, bot: configuration.bot,
                         calls: configuration.action == .call && shelved?.callable != false)
        }
    }

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "Agent", provider: Provider()) { value in
            ControlWidgetButton(action: AgentControlAction(bot: value.bot, action: value.action)) {
                Label(value.name ?? "Agent", systemImage: value.calls ? "phone.fill" : "bubble.left.fill")
            }
        }
        .displayName("Agent")
        .description("Call an agent or open your chat with it.")
        .promptsForUserConfiguration()
    }
}
