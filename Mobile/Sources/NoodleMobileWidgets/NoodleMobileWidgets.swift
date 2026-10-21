import SwiftUI
import UIKit
import WidgetKit

@main
struct NoodleMobileWidgets: WidgetBundle {
    var body: some Widget {
        BotWidget()
        BotsWidget()
    }
}

/// For the widget gallery before the app has any bots.
private enum Samples {
    static let bots = ["Scout", "Quill", "Atlas", "Nova", "Cleo", "Max", "Juno", "Otto"].map {
        WidgetBot(hub: "sample", conversationID: UUID(), name: $0, hubName: "Noodle Hub")
    }
}

// MARK: - One bot

struct BotEntry: TimelineEntry {
    let date: Date
    /// Nil when none is chosen, or the one chosen is gone.
    let bot: WidgetBot?
    let hasBots: Bool
    /// The widget's Show Call Button.
    var showsCallButton = true
}

/// The app writes the bots and reloads the widgets when they change, so there is nothing to schedule.
struct BotProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BotEntry { BotEntry(date: Date(), bot: Samples.bots[0], hasBots: true) }

    func snapshot(for configuration: BotWidgetIntent, in context: Context) async -> BotEntry {
        entry(for: configuration, preview: context.isPreview)
    }

    func timeline(for configuration: BotWidgetIntent, in context: Context) async -> Timeline<BotEntry> {
        Timeline(entries: [entry(for: configuration, preview: false)], policy: .never)
    }

    private func entry(for configuration: BotWidgetIntent, preview: Bool) -> BotEntry {
        let shelf = Shelf.load()
        if shelf.bots.isEmpty, preview { return BotEntry(date: Date(), bot: Samples.bots[0], hasBots: true) }
        return BotEntry(date: Date(), bot: configuration.bot.flatMap { shelf.bot($0.id) }, hasBots: !shelf.bots.isEmpty,
                        showsCallButton: configuration.showCallButton)
    }
}

struct BotWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Bot", intent: BotWidgetIntent.self, provider: BotProvider()) { entry in
            BotWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Bot")
        .description("Open your chat with a bot you choose, or call it.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct BotWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BotEntry

    var body: some View {
        if let bot = entry.bot {
            Group {
                if family == .accessoryCircular {
                    ZStack {
                        AccessoryWidgetBackground()
                        BotPicture(bot: bot)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(bot.name)
                } else {
                    // The picture takes what room is left; a call button sits in the corner beside the name.
                    VStack(spacing: 6) {
                        BotPicture(bot: bot).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
                        if bot.showsCallButton(setting: entry.showsCallButton) {
                            HStack(spacing: 6) {
                                BotName(name: bot.name).frame(maxWidth: .infinity, alignment: .leading)
                                CallLink(bot: bot)
                            }
                        } else {
                            BotName(name: bot.name).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .widgetURL(WidgetLink(bot).url)
        } else if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "bubble.left.and.bubble.right").font(.title3)
            }
        } else {
            Hint(text: entry.hasBots ? "Touch and hold to choose a bot." : "Open Noodle to see your bots here.")
        }
    }
}

// MARK: - Bots of a space

struct BotsEntry: TimelineEntry {
    let date: Date
    let spaceName: String
    /// Nil for a space no longer there.
    let bots: [WidgetBot]?
    let hasBots: Bool
}

struct BotsProvider: AppIntentTimelineProvider {
    private static var sample: BotsEntry { BotsEntry(date: Date(), spaceName: SpaceEntity.all.name, bots: Samples.bots, hasBots: true) }

    func placeholder(in context: Context) -> BotsEntry { Self.sample }

    func snapshot(for configuration: BotsWidgetIntent, in context: Context) async -> BotsEntry {
        entry(for: configuration, preview: context.isPreview)
    }

    func timeline(for configuration: BotsWidgetIntent, in context: Context) async -> Timeline<BotsEntry> {
        Timeline(entries: [entry(for: configuration, preview: false)], policy: .never)
    }

    private func entry(for configuration: BotsWidgetIntent, preview: Bool) -> BotsEntry {
        let shelf = Shelf.load()
        if shelf.bots.isEmpty, preview { return Self.sample }
        let space = configuration.space ?? .all
        let name = shelf.spaces.first { $0.id == space.id }?.name ?? space.name
        return BotsEntry(date: Date(), spaceName: name, bots: shelf.bots(in: space.id), hasBots: !shelf.bots.isEmpty)
    }
}

struct BotsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Bots", intent: BotsWidgetIntent.self, provider: BotsProvider()) { entry in
            BotsWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Bots")
        .description("Open your chat with any bot of a space.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct BotsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BotsEntry

    var body: some View {
        if let bots = entry.bots, !bots.isEmpty {
            // Rows of four, each bot its own link: two rows in a medium widget, four under the space's name in a large one.
            let rows = family == .systemLarge ? 4 : 2
            VStack(alignment: .leading, spacing: 10) {
                if family == .systemLarge {
                    Text(entry.spaceName).font(.headline).lineLimit(1)
                }
                BotGrid(bots: Array(bots.prefix(rows * BotGrid.columns)), rows: rows)
            }
        } else if !entry.hasBots {
            Hint(text: "Open Noodle to see your bots here.")
        } else if entry.bots == nil {
            Hint(text: "Touch and hold to choose a space.")
        } else {
            Hint(text: "No bots in \(entry.spaceName).")
        }
    }
}

/// Every cell the same size, however many bots there are, so a widget looks the same as bots come and go.
struct BotGrid: View {
    static let columns = 4
    private static let spacing: CGFloat = 8
    /// A caption line under each picture.
    private static let nameHeight: CGFloat = 18

    let bots: [WidgetBot]
    let rows: Int

    var body: some View {
        GeometryReader { geometry in
            let height = (geometry.size.height - Self.spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let width = (geometry.size.width - Self.spacing * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)
            let picture = max(16, min(width - 8, height - Self.nameHeight))
            VStack(spacing: Self.spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: Self.spacing) {
                        ForEach(0..<Self.columns, id: \.self) { column in
                            let index = row * Self.columns + column
                            if index < bots.count {
                                BotLink(bot: bots[index]) {
                                    VStack(spacing: 2) {
                                        BotPicture(bot: bots[index]).frame(width: picture, height: picture)
                                        Text(bots[index].name).font(.caption).lineLimit(1)
                                    }
                                }
                            } else {
                                Color.clear
                            }
                        }
                    }
                    .frame(height: height)
                }
            }
        }
    }
}

// MARK: - Pieces

/// Accented images lose a wrapping Link's URL in WidgetKit's archived view, so the picture stays outside the
/// link's label and a clear link covers the cell, as in the Mac's widgets. https://developer.apple.com/forums/thread/795408
private struct BotLink<Content: View>: View {
    let bot: WidgetBot
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
            .overlay {
                Link(destination: WidgetLink(bot).url) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bot.name)
            }
    }
}

/// The small widget's name, on up to two lines rather than cut short.
private struct BotName: View {
    let name: String

    var body: some View {
        Text(name).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
    }
}

/// Calls the bot, opening its chat, while a tap anywhere else opens the chat alone. Like `BotLink`, a clear link
/// covers the button rather than wrapping it, a little larger than the circle so it is easy to hit.
private struct CallLink: View {
    private static let size: CGFloat = 34
    private static let target: CGFloat = 44
    @Environment(\.widgetRenderingMode) private var renderingMode
    let bot: WidgetBot

    var body: some View {
        // Tinted, the system draws every opaque colour the same, so the glyph is told from its circle by opacity.
        let fullColor = renderingMode == .fullColor
        Image(systemName: "phone.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(fullColor ? Color.white : Color.primary)
            .frame(width: Self.size, height: Self.size)
            .background(fullColor ? Color.green : Color.primary.opacity(0.2), in: Circle())
            .widgetAccentable()
            .accessibilityHidden(true)
            .overlay {
                Link(destination: WidgetLink(bot, call: true).url) {
                    Rectangle().fill(.clear).frame(width: Self.target, height: Self.target).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Call \(bot.name)")
            }
    }
}

/// The avatar as the app drew it, or, until it has, a disc with the bot's initial.
private struct BotPicture: View {
    private static let gradients: [[Color]] = [
        [.blue, .cyan], [.purple, .pink], [.orange, .yellow], [.mint, .teal], [.indigo, .blue], [.pink, .orange],
    ]
    let bot: WidgetBot

    var body: some View {
        if let data = bot.image, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().widgetAccentedRenderingMode(.accentedDesaturated).scaledToFit()
        } else {
            let colours = Self.gradients[bot.name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.gradients.count]
            Circle().fill(LinearGradient(colors: colours, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Text(bot.name.prefix(1).uppercased())
                        .font(.system(size: 200, weight: .semibold, design: .rounded)).minimumScaleFactor(0.01)
                        .foregroundStyle(.white).padding(8)
                }
                .aspectRatio(1, contentMode: .fit)
        }
    }
}

private struct Hint: View {
    let text: String

    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
