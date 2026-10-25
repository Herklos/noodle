import Foundation
import HubLink
@testable import NoodleMobile
import SwiftUI
import Testing

@Suite struct ConversationScrollTests {
    private func message(from author: LinkMessage.Author) -> LinkMessage {
        LinkMessage(id: UUID(), conversationID: UUID(), author: author, body: "Hi", createdAt: Date(), delivered: true)
    }

    @Test func yourMessageShowsAtTheBottomWhereverYouWere() {
        #expect(ConversationScroll.target(for: message(from: .you), wasAtBottom: true) == .bottom)
        #expect(ConversationScroll.target(for: message(from: .you), wasAtBottom: false) == .bottom)
    }

    @Test func aReplyShowsFromItsTopOnlyWhenYouWereAtTheBottom() {
        #expect(ConversationScroll.target(for: message(from: .bot(UUID())), wasAtBottom: true) == .top)
        #expect(ConversationScroll.target(for: message(from: .bot(UUID())), wasAtBottom: false) == nil)
        #expect(ConversationScroll.target(for: message(from: .system), wasAtBottom: false) == nil)
    }

    @Test func atTheBottomAllowsForTheComposerAndShortConversations() {
        // 1000 of content in a 600 viewport, 100 of it under the composer: the end shows at offset 500.
        #expect(ConversationScroll.isAtBottom(contentOffset: 500, contentHeight: 1000, viewportHeight: 600, bottomInset: 100))
        #expect(!ConversationScroll.isAtBottom(contentOffset: 400, contentHeight: 1000, viewportHeight: 600, bottomInset: 100))
        #expect(ConversationScroll.isAtBottom(contentOffset: -50, contentHeight: 200, viewportHeight: 600, bottomInset: 100))
    }

    @Test func pastTheEndAllowsForTheComposerAndShortConversations() {
        // 1000 of content in a 600 viewport, 100 of it under the composer: the end shows at offset 500.
        #expect(!ConversationScroll.isPastEnd(contentOffset: 500, contentHeight: 1000, viewportHeight: 600, topInset: 50, bottomInset: 100))
        #expect(!ConversationScroll.isPastEnd(contentOffset: 400, contentHeight: 1000, viewportHeight: 600, topInset: 50, bottomInset: 100))
        // A row's worth past, as while a new row is measured, still shows most of the conversation.
        #expect(!ConversationScroll.isPastEnd(contentOffset: 560, contentHeight: 1000, viewportHeight: 600, topInset: 50, bottomInset: 100))
        // The keyboard's room taken twice leaves only empty space above the composer.
        #expect(ConversationScroll.isPastEnd(contentOffset: 800, contentHeight: 1000, viewportHeight: 600, topInset: 50, bottomInset: 100))
        // A conversation shorter than the screen ends at its start, below the bar.
        #expect(!ConversationScroll.isPastEnd(contentOffset: -50, contentHeight: 200, viewportHeight: 600, topInset: 50, bottomInset: 100))
        #expect(ConversationScroll.isPastEnd(contentOffset: 200, contentHeight: 200, viewportHeight: 600, topInset: 50, bottomInset: 100))
    }

    @Test func readingOlderMessagesStopsFollowingEvenWhenGeometryHasNotChanged() {
        var following = ConversationScroll.Following()
        // Lazy measurement already reported false while idle, so the first drag may not produce
        // another bottom-geometry callback. Starting that drag must stop following on its own.
        following.bottomChanged(false)
        #expect(following.atBottom)
        following.phaseChanged(.interacting)
        #expect(!following.atBottom)
        following.phaseChanged(.decelerating)
        following.phaseChanged(.idle)
        #expect(!following.atBottom)
        following.bottomChanged(true)
        #expect(following.atBottom)
    }

    @Test func aDragThatEndsAtTheBottomResumesFollowing() {
        var following = ConversationScroll.Following()
        following.phaseChanged(.interacting)
        #expect(!following.atBottom)
        following.phaseChanged(.idle)
        #expect(following.atBottom)
        following.phaseChanged(.animating)
        #expect(following.atBottom, "An automatic scroll is not a request to read older messages")
    }

    @Test func scrollToLatestShowsOnlyWhileTheEndIsOutOfSight() {
        var following = ConversationScroll.Following()
        #expect(!following.awayFromEnd)
        // A gap while lazy rows are measured is not the person leaving the end.
        following.bottomChanged(false)
        #expect(!following.awayFromEnd)
        following.phaseChanged(.interacting)
        #expect(following.awayFromEnd)
        following.phaseChanged(.idle)
        #expect(following.awayFromEnd, "It stays while the person reads older messages")
        following.bottomChanged(true)
        #expect(!following.awayFromEnd)
        // A drag that starts at the end shows nothing until the end is out of sight.
        following.phaseChanged(.interacting)
        #expect(!following.awayFromEnd)
        following.bottomChanged(false)
        #expect(following.awayFromEnd)
        following.phaseChanged(.idle)
        // Tapping it follows the end again at once.
        following.atBottom = true
        #expect(!following.awayFromEnd)
    }

    /// Opened, a conversation shows its end just above the composer, not past it, and does not sit
    /// shifted sideways until it is first scrolled.
    @MainActor @Test func aConversationOpensAtItsEnd() async throws {
        let messages = (0..<40).map { index in
            LinkMessage(id: UUID(), conversationID: UUID(), author: index.isMultiple(of: 2) ? .you : .bot(UUID()),
                        body: String(repeating: "Line of a message. ", count: 1 + index % 5), createdAt: Date(), delivered: true)
        }
        let conversation = NavigationStack {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(messages) { message in
                        Text(message.body).padding(8).frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .modifier(ConversationScrolling(latest: messages.last))
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 56) }
            .navigationBarTitleDisplayMode(.inline)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: conversation)
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))

        let scrollView = try #require(Self.scrollView(in: window))
        let end = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        #expect(scrollView.contentOffset.x == -scrollView.adjustedContentInset.left)
        #expect(abs(scrollView.contentOffset.y - end) <= 1)
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    @MainActor private static func layout(_ window: UIWindow) async {
        for _ in 0..<8 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.layoutIfNeeded()
        }
    }

    @MainActor @Test func aLongReplyStaysAtItsBeginningAndYourNextMessageShowsAtTheEnd() async throws {
        let model = ScrollTestMessages(messages: (0..<30).map { _ in message(from: .you) })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ScrollTestConversation(model: model))
        window.isHidden = false
        defer { window.isHidden = true }
        await Self.layout(window)
        let scroll = try #require(Self.scrollView(in: window))
        let opened = scroll.contentOffset.y

        model.messages.append(LinkMessage(id: UUID(), conversationID: UUID(), author: .bot(UUID()),
                                          body: (1...100).map { "Line \($0) of a long reply." }.joined(separator: "\n"),
                                          createdAt: Date(), delivered: true))
        await Self.layout(window)
        let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        #expect(scroll.contentOffset.y > opened, "A new reply should scroll into view")
        #expect(scroll.contentOffset.y < end - scroll.bounds.height, "A long reply should show its beginning")

        model.messages.append(message(from: .you))
        await Self.layout(window)
        let sentEnd = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        #expect(abs(scroll.contentOffset.y - sentEnd) <= 1, "Your own message should show at the end")
        #expect(abs(scroll.contentOffset.x + scroll.adjustedContentInset.left) < 1)
    }

    /// The visible input must receive taps before any drag makes the conversation lay itself out again.
    /// Load the same saved messages as a disconnected phone, without a Hub or network requests.
    @MainActor @Test(arguments: [0, 1, 50]) func theInputReceivesTapsBeforeTheFirstScroll(messageCount: Int) async throws {
        struct SavedChats: Encodable {
            let agents: [LinkBot]
            let conversations: [UUID: [LinkMessage]]
            let read: [UUID: Int]
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bot = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Wren", provider: "claude"),
                          createdAt: Date(timeIntervalSince1970: 0))
        let messages = (0..<messageCount).map { index in
            LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .bot(bot.id),
                        body: String(repeating: "A longer reply with several lines. ", count: 1 + index % 20),
                        createdAt: Date(timeIntervalSince1970: Double(index)), delivered: true)
        }
        try JSONEncoder().encode(SavedChats(agents: [bot], conversations: [bot.conversationID: messages], read: [:]))
            .write(to: folder.appendingPathComponent("chats.json"))
        let chats = HubChats(pairing: HubPairing(directory: folder, deviceName: "iPhone"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(chats: chats, threadID: bot.id)
        }.frame(width: 390, height: 700))
        window.isHidden = false
        defer { window.isHidden = true }
        // Flush queued SwiftUI updates, with explicit layout rather than a delay for an assumed device speed.
        await Self.layout(window)
        func field(in view: UIView) -> PastingTextView? {
            if let field = view as? PastingTextView { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        let input = try #require(field(in: window))
        let frame = input.convert(input.bounds, to: window)
        #expect(frame.width > 44 && frame.height > 0)
        // Include the space above and below the text inside the visible glass field.
        let halfHeight = ChatView.controlHeight / 2 - 3
        for y in [frame.midY - halfHeight, frame.midY, frame.midY + halfHeight] {
            let point = CGPoint(x: frame.midX, y: y)
            let hit = window.hitTest(point, with: nil)
            #expect(hit === input || hit?.isDescendant(of: input) == true,
                    "Input tap at \(point) reaches \(String(describing: hit)); field \(frame)")
        }
        let scroll = try #require(Self.scrollView(in: window))
        #expect(abs(scroll.contentOffset.x + scroll.adjustedContentInset.left) < 1)

        func gapAfterLastMessage() -> CGFloat {
            let end = max(scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height,
                          -scroll.adjustedContentInset.top)
            return end - scroll.contentOffset.y
        }
        let gap = gapAfterLastMessage()
        input.insertText((1...12).map { "Draft line \($0)" }.joined(separator: "\n"))
        await Self.layout(window)
        let lineHeight = try #require(input.font).lineHeight
        let textHeight = input.bounds.height - input.textContainerInset.top - input.textContainerInset.bottom
        #expect(input.isScrollEnabled)
        #expect(textHeight >= 6 * lineHeight && textHeight < 7 * lineHeight)
        #expect(abs(scroll.contentOffset.x + scroll.adjustedContentInset.left) < 1)
        #expect(abs(gapAfterLastMessage() - gap) < 1, "Growing a draft must keep the last message in place")
    }

    @Test func aPictureOfKnownSizeHoldsItsPlaceBeforeItLoads() {
        // Without a size, as from an older Hub, the placeholder stands in until the picture arrives.
        #expect(AttachmentView.pictureFrame(for: nil) == nil)
        #expect(AttachmentView.pictureFrame(for: LinkPixelSize(width: 1200, height: 900)) == CGSize(width: 240, height: 180))
        #expect(AttachmentView.pictureFrame(for: LinkPixelSize(width: 900, height: 1600)) == CGSize(width: 180, height: 320))
        // Small pictures fill the width, as they do once loaded.
        #expect(AttachmentView.pictureFrame(for: LinkPixelSize(width: 12, height: 12)) == CGSize(width: 240, height: 240))
        // A long strip stays big enough to tap.
        #expect(AttachmentView.pictureFrame(for: LinkPixelSize(width: 20_000, height: 10)) == CGSize(width: 240, height: 44))
    }
}

@MainActor @Observable private final class ScrollTestMessages {
    var messages: [LinkMessage]
    init(messages: [LinkMessage]) { self.messages = messages }
}

private struct ScrollTestConversation: View {
    let model: ScrollTestMessages

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.messages) { message in
                        Text(message.body).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).id(message.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 8)
            }
            .modifier(ConversationScrolling(latest: model.messages.last))
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 56) }
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(width: 390, height: 700)
        .transaction { $0.disablesAnimations = true }
    }
}
