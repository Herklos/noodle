import Foundation
import SwiftUI
import UIKit
@testable import NoodleMobile
import Testing

@Suite struct MessageLinkTests {
    /// On your blue bubble the tint would hide a link, so it is underlined in the text's colour instead.
    @Test func linksInYourBubbleAreUnderlined() {
        let text = MessageText.markdown("Similar to [this](https://example.com) one", onTint: true)
        let styles: [(link: URL?, underline: Text.LineStyle?)] = text.runs.map { ($0.link, $0.underlineStyle) }
        #expect(styles.filter { $0.link != nil }.map(\.underline) == [Text.LineStyle.single])
        #expect(styles.filter { $0.link == nil }.allSatisfy { $0.underline == nil })
    }

    @Test func linksInABotBubbleKeepTheTint() throws {
        let text = MessageText.markdown("Similar to [this](https://example.com) one", onTint: false)
        let underline: Text.LineStyle? = try #require(text.runs.first { $0.link != nil }).underlineStyle
        #expect(underline == nil)
    }

    /// Inline code is a size smaller and dimmer than the bubble's own text, so it sits quietly in a reply.
    @Test func inlineCodeIsSmallerAndDimmer() throws {
        let text = MessageText.markdown("Run `swift test` now.", foreground: .white)
        let code = try #require(text.runs.first { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(code.font == .system(.callout, design: .monospaced))
        #expect(code.foregroundColor == .white.opacity(0.65))
        let prose = try #require(text.runs.first { $0.inlinePresentationIntent == nil })
        #expect(prose.font == nil && prose.foregroundColor == nil)
    }

    private static let page = URL(string: "https://www.example.com/oven")!
    private static let card = LinkCard(title: "Bosch Series 4", site: "example.com", image: Data([1, 2, 3]))

    /// A link's card is fetched once and kept on the phone, across launches, until its conversation is deleted.
    @MainActor @Test func linkCardsAreKeptUntilTheConversationIsDeleted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = UUID()
        var fetches = 0
        let first = LinkPreviews(folder: folder) { _ in fetches += 1; return Self.card }
        #expect(await first.card(for: Self.page, in: conversation) == Self.card)

        let relaunched = LinkPreviews(folder: folder) { _ in fetches += 1; return nil }
        #expect(await relaunched.card(for: Self.page, in: conversation) == Self.card)
        #expect(fetches == 1)

        relaunched.forget(conversation)
        let afterDeleting = LinkPreviews(folder: folder) { _ in fetches += 1; return nil }
        #expect(await afterDeleting.card(for: Self.page, in: conversation).image == nil)
        #expect(fetches == 2)
    }

    /// The same page linked in another conversation uses the card already fetched for it; deleting
    /// either conversation leaves the other's card.
    @MainActor @Test func aLinkInTwoConversationsIsFetchedOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = UUID(), second = UUID()
        var fetches = 0
        let previews = LinkPreviews(folder: folder) { _ in fetches += 1; return Self.card }
        _ = await previews.card(for: Self.page, in: first)
        #expect(await previews.card(for: Self.page, in: second) == Self.card)
        #expect(fetches == 1)

        previews.forget(first)
        let relaunched = LinkPreviews(folder: folder) { _ in fetches += 1; return nil }
        #expect(await relaunched.card(for: Self.page, in: second) == Self.card)
        #expect(fetches == 1)
    }

    /// Cards last a week, then are fetched again, so they do not go stale.
    @MainActor @Test func linkCardsAreFetchedAgainAfterAWeek() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = UUID()
        var now = Date(timeIntervalSince1970: 1_000_000)
        var fetches = 0
        func launch() -> LinkPreviews { LinkPreviews(folder: folder, fetch: { _ in fetches += 1; return Self.card }, now: { now }) }
        _ = await launch().card(for: Self.page, in: conversation)
        now += 6 * 86_400
        _ = await launch().card(for: Self.page, in: conversation)
        #expect(fetches == 1)
        now += 2 * 86_400
        _ = await launch().card(for: Self.page, in: conversation)
        #expect(fetches == 2)
    }

    /// A card older than a week is removed at the next sync, even if its message is never shown again.
    @MainActor @Test func oldCardsAreRemovedAtTheNextSync() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = UUID()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let previews = LinkPreviews(folder: folder, fetch: { _ in Self.card }, now: { now })
        _ = await previews.card(for: Self.page, in: conversation)
        let saved = folder.appendingPathComponent(conversation.uuidString, isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: saved.path).count == 1)
        now += 8 * 86_400
        previews.keep(only: [conversation])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: saved.path)) ?? []).isEmpty)
    }

    /// A bot or group deleted on another device takes its cards with it.
    @MainActor @Test func cardsOfConversationsThatAreGoneAreForgotten() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = UUID(), gone = UUID()
        var fetches = 0
        let other = URL(string: "https://www.example.com/fridge")!
        let previews = LinkPreviews(folder: folder) { _ in fetches += 1; return Self.card }
        _ = await previews.card(for: Self.page, in: kept)
        _ = await previews.card(for: other, in: gone)
        previews.keep(only: [kept])

        let relaunched = LinkPreviews(folder: folder) { _ in fetches += 1; return nil }
        #expect(await relaunched.card(for: Self.page, in: kept) == Self.card)
        #expect(await relaunched.card(for: other, in: gone).image == nil)
        #expect(fetches == 3)
    }

    /// A page that gives nothing away still gets a card naming its site, and is tried again next launch.
    @MainActor @Test func aLinkWithoutDetailsStillGetsACard() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = UUID()
        var fetches = 0
        let previews = LinkPreviews(folder: folder) { _ in fetches += 1; return nil }
        #expect(await previews.card(for: Self.page, in: conversation) == LinkCard(title: "example.com", site: "example.com", image: nil))
        _ = await previews.card(for: Self.page, in: conversation)
        #expect(fetches == 1)

        let relaunched = LinkPreviews(folder: folder) { _ in fetches += 1; return Self.card }
        #expect(await relaunched.card(for: Self.page, in: conversation) == Self.card)
    }

    /// As drawn: a page that gives nothing away still shows a full card rather than nothing.
    @MainActor @Test func aLinkWithoutDetailsIsDrawnAsACard() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previews = LinkPreviews(folder: folder) { _ in nil }
        let host = UIHostingController(rootView: LinkPreviewCard(url: Self.page, previews: previews, conversationID: UUID()))
        // The card's own size, without the window's safe area: an iPhone Duo's has room beside the screen too.
        host.safeAreaRegions = []
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))

        let size = host.sizeThatFits(in: CGSize(width: 390, height: 1000))
        #expect(size.width == 280, "\(size)")
        #expect(size.height > 190, "\(size)")
    }
}
