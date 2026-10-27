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
        following.farFromEnd = true
        #expect(!following.awayFromEnd)
        following.phaseChanged(.interacting)
        #expect(following.awayFromEnd)
        following.phaseChanged(.idle)
        #expect(following.awayFromEnd, "It stays while the person reads older messages")
        following.bottomChanged(true)
        following.farFromEnd = false
        #expect(!following.awayFromEnd)
        // A drag that starts at the end shows nothing until the end is out of sight.
        following.phaseChanged(.interacting)
        #expect(!following.awayFromEnd)
        following.bottomChanged(false)
        following.farFromEnd = true
        #expect(following.awayFromEnd)
        following.phaseChanged(.idle)
        // Tapping it follows the end again at once.
        following.atBottom = true
        #expect(!following.awayFromEnd)
    }

    /// An iPhone conversation's geometry as SwiftUI reports it: a 852-point screen with 116 points of bars above
    /// and 90 of composer and home bar below, which `containerSize` leaves out.
    private func geometry(_ offset: CGFloat, content: CGFloat = 3000) -> ScrollGeometry {
        ScrollGeometry(contentOffset: CGPoint(x: 0, y: offset), contentSize: CGSize(width: 393, height: content),
                       contentInsets: EdgeInsets(top: 116, leading: 0, bottom: 90, trailing: 0),
                       containerSize: CGSize(width: 393, height: 852 - 116 - 90))
    }

    /// Where the end of `geometry`'s 3000 points of conversation is.
    private let end: CGFloat = 3000 + 90 - 852

    /// Measured against `containerSize`, a conversation resting at its end seemed short of it by the bars' and
    /// the composer's height, so after any drag Scroll to Latest stayed over the latest message.
    @Test func atItsEndAConversationIsAtTheBottomUnderTheBarsAndAboveTheComposer() {
        #expect(ConversationScroll.isAtBottom(geometry(end)))
        #expect(ConversationScroll.distanceFromEnd(geometry(end)) == 0)
        #expect(!ConversationScroll.isFarFromEnd(geometry(end)))
        #expect(!ConversationScroll.isPastEnd(geometry(end)))
        // Going to the end aims at it exactly, measured from below the bars, as `ScrollPosition` measures.
        #expect(ConversationScroll.Bounds(geometry(end)).end.y == end + 116)
        // On the iPhone simulator SwiftUI's sizes put the end 6 points below where the scroll view stops.
        #expect(ConversationScroll.isAtBottom(geometry(end - 6)))
        #expect(!ConversationScroll.isAtBottom(geometry(end - 150)))
        #expect(ConversationScroll.distanceFromEnd(geometry(end - 150)) == 150)
        // A conversation shorter than the screen is at its end from the start, below the bars.
        #expect(ConversationScroll.isAtBottom(geometry(-116, content: 300)))
        #expect(ConversationScroll.distanceFromEnd(geometry(-116, content: 300)) == 0)
    }

    /// With the keyboard up, going to the end aimed past it by the bars, the keyboard and the composer, more
    /// than the room left above the keyboard: the conversation went blank, and going back to the last message
    /// only aimed past the end again.
    @Test func goingToTheEndWithTheKeyboardUpStaysAtTheEnd() {
        // An 852-point screen with 116 points of bars above and 426 of keyboard and composer below.
        func keyboardUp(_ offset: CGFloat, content: CGFloat = 3000) -> ScrollGeometry {
            ScrollGeometry(contentOffset: CGPoint(x: 0, y: offset), contentSize: CGSize(width: 393, height: content),
                           contentInsets: EdgeInsets(top: 116, leading: 0, bottom: 426, trailing: 0),
                           containerSize: CGSize(width: 393, height: 852 - 116 - 426))
        }
        let realEnd: CGFloat = 3000 + 426 - 852
        // `ScrollPosition` measures from below the bars, so the scroll lands 116 points above where it aims.
        let landing = ConversationScroll.Bounds(keyboardUp(0)).end.y - 116
        #expect(landing == realEnd)
        #expect(!ConversationScroll.isPastEnd(keyboardUp(landing)))
        #expect(ConversationScroll.isAtBottom(keyboardUp(landing)))
        // A conversation shorter than the room above the keyboard ends where it starts, under the bars.
        #expect(ConversationScroll.Bounds(keyboardUp(0, content: 200)).end.y - 116 == -116)
    }

    /// The same on a real scroll view, under a navigation bar and above the composer's room.
    @MainActor @Test func aConversationRestingAtItsEndIsAtTheBottom() async throws {
        let recorded = ScrollTestGeometry()
        let conversation = NavigationStack {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(0..<60, id: \.self) { Text("Message \($0)").padding(8).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .padding(.vertical, 8)
            }
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in recorded.geometry = geometry }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 56) }
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(width: 390, height: 700)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: conversation)
        window.isHidden = false
        defer { window.isHidden = true }
        await Self.layout(window)
        let scroll = try #require(Self.scrollView(in: window))
        #expect(scroll.adjustedContentInset.top > 2 && scroll.adjustedContentInset.bottom > 2)
        let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        for above: CGFloat in [0, 150, 450] {
            scroll.contentOffset.y = end - above
            await Self.layout(window)
            let geometry = try #require(recorded.geometry)
            let seen = "\(above) points above the end; \(Self.describe(scroll)); SwiftUI: \(geometry)"
            #expect(abs(ConversationScroll.distanceFromEnd(geometry) - above) <= ConversationScroll.bottomSlack, "\(seen)")
            #expect(ConversationScroll.isAtBottom(geometry) == (above == 0), "\(seen)")
            #expect(ConversationScroll.isFarFromEnd(geometry) == (above > ConversationScroll.scrollToLatestDistance), "\(seen)")
        }
    }

    /// Petko on 0.46.0: a few lines short of the end is not reading older messages.
    @Test func scrollToLatestWaitsUntilWellAboveTheEnd() {
        let near = end - ConversationScroll.scrollToLatestDistance + 100
        let far = end - ConversationScroll.scrollToLatestDistance - 100
        #expect(!ConversationScroll.isFarFromEnd(geometry(near)))
        #expect(ConversationScroll.isFarFromEnd(geometry(far)))

        var following = ConversationScroll.Following()
        following.phaseChanged(.interacting)
        following.bottomChanged(ConversationScroll.isAtBottom(geometry(near)))
        following.farFromEnd = ConversationScroll.isFarFromEnd(geometry(near))
        following.phaseChanged(.idle)
        #expect(!following.atBottom)
        #expect(!following.awayFromEnd, "Just above the end, there is no Scroll to Latest")
        following.farFromEnd = ConversationScroll.isFarFromEnd(geometry(far))
        #expect(following.awayFromEnd, "Well above the end, Scroll to Latest shows")
        following.farFromEnd = ConversationScroll.isFarFromEnd(geometry(near))
        #expect(!following.awayFromEnd, "Back near the end, it hides again")
    }

    /// Opened, a conversation shows its end just above the composer, not past it, and does not sit
    /// shifted sideways until it is first scrolled. Under a titled bar too, which a scroll to a point measures from.
    @MainActor @Test(arguments: [false, true]) func aConversationOpensAtItsEnd(titled: Bool) async throws {
        let messages = (0..<40).map { index in
            LinkMessage(id: UUID(), conversationID: UUID(), author: index.isMultiple(of: 2) ? .you : .bot(UUID()),
                        body: String(repeating: "Line of a message. ", count: 1 + index % 5), createdAt: Date(), delivered: true)
        }
        let recorded = ScrollTestGeometry()
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
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in recorded.geometry = geometry }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 56) }
            .navigationTitle(titled ? "Conversation" : "")
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
        let seen = "\(Self.describe(scrollView)); SwiftUI: \(recorded.geometry.map(String.init(describing:)) ?? "none")"
        #expect(scrollView.contentOffset.x == -scrollView.adjustedContentInset.left, "\(seen)")
        #expect(abs(scrollView.contentOffset.y - end) <= 1, "\(seen)")
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    /// What the scroll view itself has, to set beside SwiftUI's geometry when a test fails.
    @MainActor private static func describe(_ scroll: UIScrollView) -> String {
        "UIScrollView: contentOffset \(scroll.contentOffset), contentSize \(scroll.contentSize), "
            + "adjustedContentInset \(scroll.adjustedContentInset), bounds \(scroll.bounds)"
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
        #expect(abs(scroll.contentOffset.y - sentEnd) <= 1, "Your own message should show at the end; \(Self.describe(scroll))")
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

@MainActor private final class ScrollTestGeometry {
    var geometry: ScrollGeometry?
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
