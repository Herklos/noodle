import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// The transcript's reading position, hosted in windows that are never shown on screen.
@MainActor final class TranscriptScrollTests: HiddenViewTests {
    /// A long history whose rows carry attachments opens on its last message at
    /// narrow, medium and wide windows, even when the messages arrive after the
    /// transcript is already mounted.
    func testAttachmentHeavyHistoryOpensOnItsLastMessage() async throws {
        for width: CGFloat in [820, 550, 1100] {
            let model = StartupModel()
            let root = mount(StartupFixture(model: model))
            let window = try XCTUnwrap(root.window)
            window.setContentSize(.init(width: width, height: 780))
            root.layoutSubtreeIfNeeded()
            model.ids = (0..<180).map { _ in UUID() }
            model.overlay = 75
            let last = try XCTUnwrap(model.ids.last)
            let rendered = await eventually { model.visible.contains(last) }
            XCTAssertTrue(rendered, "At width \(width) the last message was not rendered; visible rows \(model.indices(of: model.visible))")
            window.close(); window.contentView = nil
        }
    }

    /// Content that finishes loading in rows above the one being read, such as a
    /// picture replacing its placeholder, leaves that row where it was on screen.
    func testRowsGrowingAboveKeepTheReadRowInPlace() async throws {
        let ids = (0..<180).map { _ in UUID() }
        let reading = ids[100]
        let model = StartupModel(initialViewport: TranscriptViewport(offset: 1, isAtBottom: false, messageID: reading))
        let root = mount(StartupFixture(model: model))
        model.ids = ids
        model.overlay = 75
        let opened = await eventually { model.tops[reading] != nil }
        XCTAssertTrue(opened, "The read message was not rendered")
        // Let restoration settle before measuring.
        _ = await eventually(seconds: 1) { false }
        let before = try XCTUnwrap(model.tops[reading])
        model.grown = Set(ids[90..<100])
        _ = await eventually(seconds: 1) { false }
        let after = try XCTUnwrap(model.tops[reading], "The read message scrolled out of view")
        XCTAssertEqual(after, before, accuracy: 2, "The read message moved \(after - before)pt when rows above it grew")
        _ = root
    }

    /// Rows far taller or shorter than the lazy stack's estimate still open on a
    /// filled screen that ends with the last message, not on a blank gap.
    func testUnevenRowsOpenOnAFilledScreenEndingWithTheLastMessage() async throws {
        for seed in 0..<4 {
            let model = StartupModel()
            let root = mount(StartupFixture(model: model))
            let ids = (0..<200).map { _ in UUID() }
            model.extra = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
                (id, CGFloat([0, 0, 600, 0, 40, 900, 0, 0, 1400][(index + seed) % 9]))
            })
            model.ids = ids
            model.overlay = 75
            let last = try XCTUnwrap(ids.last)
            let rendered = await eventually { model.visible.contains(last) }
            _ = await eventually(seconds: 1) { false }
            XCTAssertTrue(rendered, "Seed \(seed): the last message was not rendered; visible rows \(model.indices(of: model.visible))")
            assertFilled(model, root, "Seed \(seed) on open")
            assertLastMessageShows(model, root, "Seed \(seed) on open")
        }
    }

    /// An earlier page prepended while the end is being read, as paging does,
    /// neither moves the end away nor leaves a blank screen.
    func testAnEarlierPageLoadingAboveKeepsTheEndInView() async throws {
        let model = StartupModel()
        let root = mount(StartupFixture(model: model))
        let ids = (0..<160).map { _ in UUID() }
        model.overlay = 75
        model.ids = Array(ids.suffix(40))
        let last = try XCTUnwrap(ids.last)
        _ = await eventually { model.visible.contains(last) }
        _ = await eventually(seconds: 1) { false }
        model.ids = ids
        _ = await eventually(seconds: 1) { false }
        assertFilled(model, root, "After the earlier page loaded")
        assertLastMessageShows(model, root, "After the earlier page loaded")
    }

    /// An earlier page loading above the row being read leaves that row where it was on screen.
    func testAnEarlierPageLoadingAboveKeepsTheReadRowInPlace() async throws {
        let ids = (0..<160).map { _ in UUID() }
        let reading = ids[125]
        let model = StartupModel(initialViewport: TranscriptViewport(offset: 1, isAtBottom: false, messageID: reading))
        let root = mount(StartupFixture(model: model))
        model.ids = Array(ids.suffix(40))
        model.overlay = 75
        let opened = await eventually { model.tops[reading] != nil }
        XCTAssertTrue(opened, "The read message was not rendered")
        _ = await eventually(seconds: 1) { false }
        let before = try XCTUnwrap(model.tops[reading])
        model.ids = ids
        _ = await eventually(seconds: 1) { false }
        let after = try XCTUnwrap(model.tops[reading], "The read message scrolled out of view")
        XCTAssertEqual(after, before, accuracy: 2, "The read message moved \(after - before)pt when an earlier page loaded")
        _ = root
    }

    /// Switching to another conversation opens that one on its own last message.
    func testSwitchingConversationsOpensTheNextOnItsLastMessage() async throws {
        let model = StartupModel()
        let root = mount(StartupFixture(model: model))
        model.overlay = 75
        for round in 0..<4 {
            let ids = (0..<(80 + round * 50)).map { _ in UUID() }
            model.extra = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
                (id, CGFloat(index % (5 + round) == 0 ? 800 : 0))
            })
            model.conversationID = UUID()
            model.ids = ids
            let last = try XCTUnwrap(ids.last)
            let rendered = await eventually { model.visible.contains(last) }
            _ = await eventually(seconds: 1) { false }
            XCTAssertTrue(rendered, "Conversation \(round): the last message was not rendered; visible rows \(model.indices(of: model.visible))")
            assertFilled(model, root, "Conversation \(round)")
            assertLastMessageShows(model, root, "Conversation \(round)")
        }
    }

    /// Scrolled up and then back down to the end by hand, under the titlebar as
    /// in the chat window, a transcript follows new messages again.
    func testScrollingBackToTheEndByHandFollowsNewMessagesAgain() async throws {
        let (model, root, scroll) = try await openUnderTitlebar()
        var saved: TranscriptViewport?
        model.persist = { saved = $0 }
        XCTAssertGreaterThan(scroll.contentInsets.top, 2, "The transcript must run up behind the titlebar")
        await scrollUp(scroll)
        XCTAssertEqual(saved?.isAtBottom, false)
        await scrollDownToTheEnd(scroll)
        XCTAssertEqual(saved?.isAtBottom, true, "Scrolled to \(endOffset(scroll) - scroll.contentView.bounds.minY)pt "
            + "from the end under a \(scroll.contentInsets.top)pt titlebar, it was not taken for the end")
        model.ids.append(UUID())
        _ = await eventually(seconds: 1) { false }
        assertLastMessageShows(model, root, "After a new message")
    }

    /// Scroll to Latest shows only away from the end. It goes back there, and
    /// new messages follow again.
    func testScrollToLatestGoesBackToTheEndAndFollowsAgain() async throws {
        let (model, root, scroll) = try await openUnderTitlebar()
        XCTAssertFalse(hasControl("Scroll to Latest", in: root), "At the end there is no Scroll to Latest")
        await scrollUp(scroll)
        press(try await control("Scroll to Latest", in: root))
        let hidden = await eventually { !self.hasControl("Scroll to Latest", in: root) }
        XCTAssertTrue(hidden, "Scroll to Latest stayed after going back to the end")
        _ = await eventually(seconds: 1) { false }
        assertLastMessageShows(model, root, "After Scroll to Latest")
        model.ids.append(UUID())
        _ = await eventually(seconds: 1) { false }
        assertLastMessageShows(model, root, "After a new message")
        XCTAssertFalse(hasControl("Scroll to Latest", in: root), "Following new messages, there is no Scroll to Latest")
    }

    /// A little above the end is not reading older messages: Scroll to Latest waits until the end is
    /// more than `TranscriptScrollMetrics.scrollToLatestDistance` below, as on iPhone.
    func testScrollToLatestWaitsUntilWellAboveTheEnd() async throws {
        let (_, root, scroll) = try await openUnderTitlebar()
        await scrollUp(scroll, by: 200, step: 50)
        let near = endOffset(scroll) - scroll.contentView.bounds.minY
        XCTAssertGreaterThan(near, 50, "The scroll did not leave the end")
        XCTAssertLessThan(near, TranscriptScrollMetrics.scrollToLatestDistance, "The scroll went too far")
        XCTAssertFalse(hasControl("Scroll to Latest", in: root), "\(near)pt above the end, Scroll to Latest showed")
        await scrollUp(scroll, by: 900)
        let shown = await eventually(seconds: 2) { self.hasControl("Scroll to Latest", in: root) }
        XCTAssertTrue(shown, "\(endOffset(scroll) - scroll.contentView.bounds.minY)pt above the end, there was no Scroll to Latest")
    }

    // MARK: - Helpers

    /// A long conversation opened on its end, running up behind the titlebar as the chat window's does.
    private func openUnderTitlebar() async throws -> (StartupModel, NSView, NSScrollView) {
        let model = StartupModel()
        let root = mount(StartupFixture(model: model))
        let window = try XCTUnwrap(root.window)
        window.styleMask.insert(.fullSizeContentView)
        // Native scroll phases need a rendered viewport; the window stays offscreen.
        window.orderFront(nil)
        model.ids = (0..<120).map { _ in UUID() }
        model.overlay = 75
        let last = try XCTUnwrap(model.ids.last)
        let opened = await eventually { model.visible.contains(last) }
        XCTAssertTrue(opened, "The last message was not rendered")
        _ = await eventually(seconds: 1) { false }
        return (model, root, try XCTUnwrap(scrollView(in: root)))
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        view as? NSScrollView ?? view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func scrollUp(_ scroll: NSScrollView, by distance: Int32 = 1800, step: Int32 = 300) async {
        wheel(scroll, delta: 0, phase: 1)
        for scrolled in stride(from: Int32(0), to: distance, by: Int(step)) {
            wheel(scroll, delta: min(step, distance - scrolled), phase: 2)
            _ = await eventually(seconds: 0.03) { false }
        }
        wheel(scroll, delta: 0, phase: 4)
        _ = await eventually(seconds: 1) { false }
    }

    /// Scrolls down to exactly the end, as a hand stops there, without overscrolling past it.
    private func scrollDownToTheEnd(_ scroll: NSScrollView) async {
        wheel(scroll, delta: 0, phase: 1)
        for _ in 0..<40 {
            let distance = endOffset(scroll) - scroll.contentView.bounds.minY
            guard distance >= 0.5 else { break }
            wheel(scroll, delta: -Int32(min(distance, 400).rounded()), phase: 2)
            _ = await eventually(seconds: 0.03) { false }
        }
        wheel(scroll, delta: 0, phase: 4)
        _ = await eventually(seconds: 1) { false }
    }

    /// The clip view's origin at the end of the transcript.
    private func endOffset(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) + scroll.contentInsets.bottom - scroll.contentView.bounds.height
    }

    private func wheel(_ scroll: NSScrollView, delta: Int32, phase: Int64) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0) else { return XCTFail("No scroll event") }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        guard let native = NSEvent(cgEvent: event) else { return XCTFail("No scroll event") }
        scroll.scrollWheel(with: native)
    }

    /// Fails when rows leave a blank stretch in the part of the screen above the composer.
    private func assertFilled(_ model: StartupModel, _ root: NSView, _ context: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let bottom = root.bounds.height - model.overlay - 20
        let gap = model.largestGap(from: 0, to: bottom)
        XCTAssertLessThan(gap, 40, "\(context): a \(gap)pt blank stretch in a \(bottom)pt screen; rows \(model.describeVisible())",
                          file: file, line: line)
    }

    /// Fails unless the last message ends on screen, above the composer.
    private func assertLastMessageShows(_ model: StartupModel, _ root: NSView, _ context: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard let last = model.ids.last, let frame = model.frames[last] else {
            return XCTFail("\(context): the last message is not on screen; rows \(model.describeVisible())", file: file, line: line)
        }
        let limit = root.bounds.height - model.overlay
        XCTAssertLessThanOrEqual(frame.maxY, limit + 2, "\(context): the last message ends at \(frame.maxY), under the composer at \(limit)",
                                 file: file, line: line)
        XCTAssertGreaterThan(frame.maxY, limit - 120, "\(context): the last message ends at \(frame.maxY), far above the composer at \(limit)",
                             file: file, line: line)
    }

    /// Hosted transcripts; a window that is never ordered in gets no display
    /// cycle, so polling lays them out the way a visible window would.
    private var roots: [NSView] = []

    private func mount<V: View>(_ view: V) -> NSHostingView<V> {
        let root = host(view)
        roots.append(root)
        return root
    }

    /// Polls until `predicate` holds, returning false after `seconds` so the
    /// caller can fail with its own message.
    private func eventually(seconds: Double = 15, _ predicate: () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        while true {
            for root in roots where root.window != nil { root.layoutSubtreeIfNeeded(); root.displayIfNeeded() }
            if predicate() { return true }
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor private final class StartupModel: ObservableObject {
    @Published var conversationID = UUID()
    @Published var ids: [UUID] = []
    /// Extra height per row, making the rows' real heights stray from the lazy stack's estimate.
    @Published var extra: [UUID: CGFloat] = [:]
    @Published var overlay: CGFloat = 0
    /// Rows whose late content has loaded, making them taller.
    @Published var grown: Set<UUID> = []
    var visible: Set<UUID> = []
    /// Each rendered row's frame, in the scroll view's visible coordinates.
    var frames: [UUID: CGRect] = [:]
    var tops: [UUID: CGFloat] { frames.mapValues(\.minY) }
    let initialViewport: TranscriptViewport
    var lastMessageIsFromUser = false
    var persist: ((TranscriptViewport) -> Void)?

    init(initialViewport: TranscriptViewport = TranscriptViewport()) { self.initialViewport = initialViewport }

    func indices(of ids: Set<UUID>) -> [Int] { ids.compactMap { self.ids.firstIndex(of: $0) }.sorted() }

    /// The tallest stretch of `from...to` that no rendered row covers.
    func largestGap(from top: CGFloat, to bottom: CGFloat) -> CGFloat {
        var reached = top, gap: CGFloat = 0
        for frame in frames.values.sorted(by: { $0.minY < $1.minY }) where frame.maxY > top && frame.minY < bottom {
            gap = max(gap, frame.minY - reached)
            reached = max(reached, frame.maxY)
        }
        return max(gap, bottom - reached)
    }

    func describeVisible() -> String {
        frames.compactMap { id, frame in ids.firstIndex(of: id).map { ($0, frame) } }.sorted { $0.0 < $1.0 }
            .map { "\($0.0)@\(Int($0.1.minY))..\(Int($0.1.maxY))" }.joined(separator: " ")
    }
}

/// The chat's transcript arrangement: a dissolve surface, a header, rows with
/// attachment placeholders, a top fade and a composer overlaid at the bottom.
private struct StartupFixture: View {
    @ObservedObject var model: StartupModel
    var body: some View {
        ConversationTransition(conversationID: model.conversationID) {
            transcript
                .id(model.conversationID)
                .transaction { $0.animation = nil }
        }
        // As in the chat, the transcript runs up behind the titlebar of a full-size content window.
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .bottom) { Text("Composer").frame(height: 60) }
    }

    private var transcript: some View {
        TranscriptScrollView(initialViewport: model.initialViewport, lastMessageID: model.ids.last,
            lastMessageIsFromUser: model.lastMessageIsFromUser, bottomOverlayHeight: model.overlay,
            saveViewport: { model.persist?($0) }) {
            Text("Conversation header").frame(height: 180).id(TranscriptScrollTarget.start)
            ForEach(Array(model.ids.enumerated()), id: \.element) { index, id in
                HStack(alignment: .bottom) {
                    Circle().fill(.blue).frame(width: 27, height: 27)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Message \(index) " + String(repeating: "A paragraph of selectable conversation text. ", count: index % 17 + 1))
                            .font(.system(size: 12.5)).textSelection(.enabled)
                            .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                        if index % 13 == 0 || id == model.ids.last {
                            ForEach(0..<2) { attachment in
                                VStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.2)).frame(width: 280, height: 166)
                                    Text("Document \(attachment).pdf").font(.caption)
                                }
                            }
                        }
                        if let extra = model.extra[id], extra > 0 {
                            RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.1)).frame(width: 200, height: extra)
                        }
                        if model.grown.contains(id) {
                            RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.2)).frame(width: 280, height: 200)
                        }
                    }
                    Spacer(minLength: 120)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { model.frames[id] = $0 }
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    if visible { model.visible.insert(id) } else { model.visible.remove(id) }
                }
                .onDisappear { model.visible.remove(id); model.frames[id] = nil }
                .id(TranscriptScrollTarget.message(id))
            }
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: 88)
                Color.white
            }.ignoresSafeArea(edges: .top)
        }
    }
}
