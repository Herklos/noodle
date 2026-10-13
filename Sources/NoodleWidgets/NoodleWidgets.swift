import NoodleCore
import NoodleWallpaper
import SwiftUI
import WidgetKit

struct BotsEntry: TimelineEntry {
    let date: Date
    let bots: [WidgetBot]
}

/// Noodle writes the bots and reloads the widgets when they change, so there is nothing to schedule.
struct BotsProvider: TimelineProvider {
    func placeholder(in context: Context) -> BotsEntry { BotsEntry(date: Date(), bots: Self.samples) }

    func getSnapshot(in context: Context, completion: @escaping (BotsEntry) -> Void) {
        let bots = BotWidgetShelf.configured()?.load() ?? []
        completion(BotsEntry(date: Date(), bots: bots.isEmpty && context.isPreview ? Self.samples : bots))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BotsEntry>) -> Void) {
        completion(Timeline(entries: [BotsEntry(date: Date(), bots: BotWidgetShelf.configured()?.load() ?? [])], policy: .never))
    }

    /// For the widget gallery before Noodle has any bots.
    static let samples: [WidgetBot] = [
        WidgetBot(id: UUID(), conversationID: UUID(), name: "Alfred", symbol: "sparkles", colour: 0,
                  status: "Planning the week", isWorking: true),
        WidgetBot(id: UUID(), conversationID: UUID(), name: "Cleo", symbol: "paintbrush.fill", colour: 3,
                  status: "Sketching the poster", finishedAt: Date().addingTimeInterval(-300)),
        WidgetBot(id: UUID(), conversationID: UUID(), name: "Max", symbol: "hammer.fill", colour: 5,
                  finishedAt: Date().addingTimeInterval(-3_600)),
        WidgetBot(id: UUID(), conversationID: UUID(), name: "Nova", symbol: "globe", colour: 1),
    ]
}

private let scheme = Bundle.main.object(forInfoDictionaryKey: "NoodleURLScheme") as? String ?? "noodle"

private struct BotPicture: View {
    let bot: WidgetBot
    let size: CGFloat

    var body: some View {
        // Noodle draws the avatar; a widget on the desktop behind a window is drawn without colour, and an
        // image left to that would become a flat disc.
        if let data = bot.image, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().widgetAccentedRenderingMode(.desaturated)
                .frame(width: size, height: size).clipShape(Circle())
        } else {
            IconBadge(appearance: IconAppearance(symbol: bot.symbol, colour: bot.colour), symbol: "sparkles",
                      size: size, showsShadow: false)
        }
    }
}

private struct NoBots: View {
    var body: some View {
        Text("No Bots").font(.headline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Accented images lose a wrapping Link's URL in WidgetKit's archived view.
/// Keep the image outside the action's label, and cover the visible cell with a
/// separate Link. https://developer.apple.com/forums/thread/795408
struct BotWidgetLink<Content: View>: View {
    let destination: URL
    let name: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().accessibilityHidden(true)
            .overlay {
                Link(destination: destination) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            }
    }
}

// MARK: - Launcher

struct BotLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BotLauncher", provider: BotsProvider()) { entry in
            BotLauncherView(bots: entry.bots).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bots")
        .description("Open a chat with one of your bots.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct BotLauncherView: View {
    @Environment(\.widgetFamily) private var family
    let bots: [WidgetBot]

    var body: some View { BotLauncherContents(bots: bots, family: family) }
}

struct BotLauncherContents: View {
    let bots: [WidgetBot]
    let family: WidgetFamily

    var body: some View {
        if bots.isEmpty {
            NoBots()
        } else if family == .systemSmall, let bot = bots.first {
            // A small widget opens one link, so it holds the first bot alone.
            VStack(spacing: 8) {
                BotPicture(bot: bot, size: 72)
                Text(bot.name).font(.headline).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(WidgetBots.link(to: bot, scheme: scheme))
        } else {
            // Rows of four, each bot its own link.
            let shown = Array(bots.prefix(family == .systemLarge ? 16 : 8))
            VStack(spacing: 10) {
                ForEach(Array(stride(from: 0, to: shown.count, by: 4)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(start..<start + 4, id: \.self) { index in
                            if index < shown.count {
                                BotWidgetLink(destination: WidgetBots.link(to: shown[index], scheme: scheme),
                                              name: shown[index].name) {
                                    VStack(spacing: 4) {
                                        BotPicture(bot: shown[index], size: 44)
                                        Text(shown[index].name).font(.caption).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                }
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Status

struct BotStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BotStatus", provider: BotsProvider()) { entry in
            BotStatusView(bots: WidgetBots.recent(entry.bots)).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bot Status")
        .description("See which bots are working and which have finished.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct BotStatusView: View {
    @Environment(\.widgetFamily) private var family
    let bots: [WidgetBot]

    var body: some View { BotStatusContents(bots: bots, family: family) }
}

struct BotStatusContents: View {
    let bots: [WidgetBot]
    let family: WidgetFamily

    var body: some View {
        if bots.isEmpty {
            NoBots()
        } else if family == .systemSmall, let bot = bots.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    BotPicture(bot: bot, size: 32)
                    Text(bot.name).font(.headline).lineLimit(1)
                }
                if let status = bot.status { Text(status).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                Spacer(minLength: 0)
                BotState(bot: bot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(WidgetBots.link(to: bot, scheme: scheme))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(bots.prefix(family == .systemLarge ? 7 : 3)) { bot in
                    BotWidgetLink(destination: WidgetBots.link(to: bot, scheme: scheme),
                                  name: [bot.name, bot.status, bot.isWorking ? "Working" : nil].compactMap { $0 }.joined(separator: ", ")) {
                        BotStatusRow(bot: bot).contentShape(Rectangle())
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct BotStatusRow: View {
    let bot: WidgetBot

    var body: some View {
        HStack(spacing: 10) {
            BotPicture(bot: bot, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name).font(.headline).lineLimit(1)
                // Blank rather than left out, so every row has the same height.
                Text(bot.status ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            BotState(bot: bot)
        }
    }
}

/// Shown only while the bot works; a bot without it has finished.
private struct BotState: View {
    let bot: WidgetBot

    var body: some View {
        if bot.isWorking {
            Label("Working", systemImage: "ellipsis.circle.fill").foregroundStyle(.blue)
                .font(.caption.weight(.medium)).lineLimit(1)
        }
    }
}
