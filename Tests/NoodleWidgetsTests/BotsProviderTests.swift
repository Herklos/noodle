import NoodleCore
import WidgetKit
import XCTest
@testable import NoodleWidgets

final class BotsProviderTests: XCTestCase {
    private let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]

    func testGalleryShowsSamplesInEverySizeOfBothWidgets() throws {
        let shelf = try shelf(bots(20))
        for kind in [BotWidgetKind.launcher, .status] {
            for family in families {
                let shown = BotsProvider.bots(for: kind, family: family, isPreview: true, shelf: shelf)
                XCTAssertFalse(shown.isEmpty, "\(kind) \(family)")
                XCTAssertTrue(shown.allSatisfy { bot in BotsProvider.samples.contains { $0.id == bot.id } },
                              "\(kind) \(family) shows the samples, not the bots on the shelf")
            }
        }
        XCTAssertEqual(BotsProvider.bots(for: .launcher, family: .systemLarge, isPreview: true, shelf: nil).count, 8)
        XCTAssertEqual(BotsProvider.bots(for: .status, family: .systemLarge, isPreview: true, shelf: nil).count, 7)
    }

    func testWidgetReadsOnlyTheBotsItShows() throws {
        let all = bots(20)
        let shelf = try shelf(all)
        let launcher = BotsProvider.bots(for: .launcher, family: .systemMedium, isPreview: false, shelf: shelf)
        XCTAssertEqual(launcher.map(\.id), all.prefix(8).map(\.id))
        XCTAssertEqual(launcher.map(\.image), all.prefix(8).map(\.image))
        XCTAssertEqual(BotsProvider.bots(for: .launcher, family: .systemLarge, isPreview: false, shelf: shelf).count, 16)

        let status = BotsProvider.bots(for: .status, family: .systemSmall, isPreview: false, shelf: shelf)
        XCTAssertEqual(status.map(\.name), ["Bot 19"], "The most recently finished")
        XCTAssertEqual(status.first?.image, all.last?.image)
        XCTAssertEqual(BotsProvider.bots(for: .status, family: .systemLarge, isPreview: false, shelf: shelf).count, 7)
    }

    private func bots(_ count: Int) -> [WidgetBot] {
        (0..<count).map { index in
            WidgetBot(id: UUID(), conversationID: UUID(), name: "Bot \(index)", image: Data("picture \(index)".utf8),
                      status: "Status \(index)", finishedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)))
        }
    }

    private func shelf(_ bots: [WidgetBot]) throws -> BotWidgetShelf {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-widget-provider-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let shelf = BotWidgetShelf(rootURL: root)
        try shelf.save(bots)
        return shelf
    }
}
