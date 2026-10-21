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
        // The keyboard's room taken twice leaves only empty space above the composer.
        #expect(ConversationScroll.isPastEnd(contentOffset: 800, contentHeight: 1000, viewportHeight: 600, topInset: 50, bottomInset: 100))
        // A conversation shorter than the screen ends at its start, below the bar.
        #expect(!ConversationScroll.isPastEnd(contentOffset: -50, contentHeight: 200, viewportHeight: 600, topInset: 50, bottomInset: 100))
        #expect(ConversationScroll.isPastEnd(contentOffset: 100, contentHeight: 200, viewportHeight: 600, topInset: 50, bottomInset: 100))
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
