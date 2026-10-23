import AppIntents
import HubLink
import UIKit
import UniformTypeIdentifiers

// Actions for Shortcuts and Siri, named, asking and spoken as the Mac's are. Call Agent and Open Chat open the app by the
// link a widget uses, so the app does the calling; Send to Agent sends straight to the Hub, as the share sheet does.

/// A bot or group, as the share sheet offers it.
struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Noodle Conversation",
        numericFormat: "\(placeholder: .int) Noodle conversations"
    )
    static let defaultQuery = ConversationQuery()

    /// A bot's is the one its widgets and Call Agent know it by.
    let id: String
    let name: String
    let isGroup: Bool
    /// Its Hub's name, when bots of several Hubs are offered.
    let hubName: String?

    var displayRepresentation: DisplayRepresentation {
        let kind = isGroup ? "Group" : "Agent"
        return DisplayRepresentation(title: "\(name)", subtitle: "\(hubName.map { "\(kind), \($0)" } ?? kind)",
                                     image: .init(systemName: isGroup ? "person.3.fill" : "person.crop.circle"))
    }
}

/// Every Hub's bots and groups, as the share sheet orders them.
struct ConversationQuery: EntityStringQuery {
    func entities(for identifiers: [ConversationEntity.ID]) async throws -> [ConversationEntity] {
        let all = await ShortcutConversations.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        await ShortcutConversations.all(matching: string)
    }

    func suggestedEntities() async throws -> [ConversationEntity] { await ShortcutConversations.all() }
}

/// What the Shortcuts actions find and send, from what the app last left for the share sheet.
@MainActor enum ShortcutConversations {
    static func all(in hubs: URL? = AppGroup.hubs, matching string: String = "") -> [ConversationEntity] {
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return found(in: hubs).map(\.entity).filter { term.isEmpty || $0.name.localizedStandardContains(term) }
    }

    /// The link that opens its chat.
    static func link(to id: ConversationEntity.ID, in hubs: URL? = AppGroup.hubs) throws -> WidgetLink {
        try conversation(id, in: hubs).link
    }

    /// Words, files or both. A file goes by its location when Shortcuts gives one.
    static func send(_ body: String, files: [IntentFile], to id: ConversationEntity.ID, in hubs: URL? = AppGroup.hubs) async throws {
        let found = try conversation(id, in: hubs)
        guard let hubs else { throw ConversationGone() }
        let outgoing = try files.map { file in
            let filename = file.filename.isEmpty ? "File" : file.filename
            if let url = file.fileURL { return try PickedFiles.copy(url, named: filename) }
            return try PickedFiles.store(file.data, named: filename,
                                         type: file.type ?? UTType(filenameExtension: (filename as NSString).pathExtension))
        }
        try await SharedSend.send(body, files: outgoing, to: found.target, hubs: hubs)
    }

    private struct Found {
        let entity: ConversationEntity
        let target: ShareTarget
        let link: WidgetLink
    }

    private static func conversation(_ id: ConversationEntity.ID, in hubs: URL?) throws -> Found {
        guard let found = found(in: hubs).first(where: { $0.entity.id == id }) else { throw ConversationGone() }
        return found
    }

    private static func found(in hubs: URL?) -> [Found] {
        guard let hubs else { return [] }
        let targets = ShareTargets.all(in: hubs)
        let namesHubs = Set(targets.map(\.key.hub)).count > 1
        // A widget's link names the Hub by its key, as spaces do, not by its folder.
        var spaces: [String: String] = [:]
        return targets.map { target in
            let space = spaces[target.key.hub] ?? CurrentHub.space(of: HubPairing(
                directory: hubs.appendingPathComponent(target.key.hub, isDirectory: true), deviceName: ""))
            spaces[target.key.hub] = space
            let link = WidgetLink(hub: space, conversationID: target.key.conversation)
            return Found(entity: ConversationEntity(id: WidgetBot.id(hub: space, conversationID: target.key.conversation),
                                                    name: target.name, isGroup: target.isGroup,
                                                    hubName: namesHubs ? target.hubName : nil),
                         target: target, link: link)
        }
    }
}

struct ConversationGone: LocalizedError {
    var errorDescription: String? { "That chat is no longer available. Open Noodle to see your agents." }
}

struct SendToAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to Agent"
    static let description = IntentDescription(
        "Send a message or files to a Noodle agent or group of agents. Replies appear in the conversation in Noodle.",
        searchKeywords: ["Send to Bot", "Send to a Bot", "Bot", "Send File", "Send and Open"]
    )

    @Parameter(
        title: "Agent or Group",
        description: "The agent or group of agents that should receive the message.",
        requestValueDialog: "Who should receive the message?"
    )
    var conversation: ConversationEntity

    @Parameter(
        title: "Message",
        description: "The question, instruction, or message to send.",
        requestValueDialog: "What would you like to send?"
    )
    var command: String?

    @Parameter(title: "Files", description: "Files to send with the message.")
    var files: [IntentFile]?

    @Parameter(title: "Open Chat", description: "Open the chat in Noodle after sending.", default: false)
    var opensConversation: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$command) to \(\.$conversation)") {
            \.$files
            \.$opensConversation
        }
    }

    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = files ?? []
        guard !text.isEmpty || !files.isEmpty else { throw $command.needsValueError("What would you like to send?") }
        try await ShortcutConversations.send(text, files: files, to: conversation.id)
        if opensConversation {
            let link = try ShortcutConversations.link(to: conversation.id)
            try await continueInForeground(alwaysConfirm: false)
            _ = await UIApplication.shared.open(link.url)
        }
        return .result(dialog: "Sent to \(conversation.name).")
    }
}

/// Opens the chat with a bot or group. It was Open Chat with Agent, for bots alone, in the widgets; the type and its
/// `bot` stay, and a bot keeps its ID, so Shortcuts made then still find the action and may keep their bot.
struct OpenAgentChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription(
        "Open your chat with a Noodle agent or group of agents.",
        searchKeywords: ["Open Chat with Agent", "Open Chat with Bot", "Open Conversation", "Conversation", "Chat with Bot",
                         "Bot", "Group"]
    )

    @Parameter(title: "Agent or Group", requestValueDialog: "Which chat should Noodle open?")
    var bot: ConversationEntity?

    init() {}

    init(conversation: ConversationEntity?) { bot = conversation }

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$bot)") }

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        guard let bot else { throw $bot.needsValueError() }
        return .result(opensIntent: OpenURLIntent(try ShortcutConversations.link(to: bot.id).url))
    }
}

/// Calls a bot, opening its chat; one that takes no calls just has its chat opened.
struct CallAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Call Agent"
    static let description = IntentDescription(
        "Call a Noodle agent. If it can't take calls, your chat with it opens instead.",
        searchKeywords: ["Call Bot", "Call a Bot", "Bot"]
    )

    @Parameter(title: "Agent", requestValueDialog: "Which agent should Noodle call?")
    var bot: BotEntity?

    init() {}

    init(bot: BotEntity?) { self.bot = bot }

    static var parameterSummary: some ParameterSummary { Summary("Call \(\.$bot)") }

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let bot else { throw $bot.needsValueError() }
        return .result(opensIntent: OpenURLIntent(WidgetLink(calling: try Shelf.bot(bot)).url))
    }
}

struct NoodleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToAgentIntent(),
            phrases: [
                "Send to an agent with \(.applicationName)",
                "Send to a bot with \(.applicationName)",
                "Send to \(\.$conversation) with \(.applicationName)",
                "Send a command with \(.applicationName)",
                "Message \(\.$conversation) with \(.applicationName)",
                "Tell \(\.$conversation) using \(.applicationName)"
            ],
            shortTitle: "Send to Agent",
            systemImageName: "paperplane.fill"
        )
        AppShortcut(
            intent: OpenAgentChatIntent(),
            phrases: [
                "Open a chat in \(.applicationName)",
                "Open chat with \(\.$bot) in \(.applicationName)",
                "Open \(\.$bot) in \(.applicationName)",
                "Open my chat with \(\.$bot) in \(.applicationName)"
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
        AppShortcut(
            intent: CallAgentIntent(),
            phrases: [
                "Call an agent with \(.applicationName)",
                "Call a bot with \(.applicationName)",
                "Call \(\.$bot) with \(.applicationName)"
            ],
            shortTitle: "Call Agent",
            systemImageName: "phone.fill"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
