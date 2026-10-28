#if NOODLE_DEV_HOOKS
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleWallpaper
import SwiftUI
import UniformTypeIdentifiers

/// Prototype of the Columns layout: several full conversations side by side in the main window.
/// Development builds only, switched on with the toolbar's List/Columns control.
enum MainWindowLayout: String {
    case list, columns
    static let key = "NoodlePrototypeLayout"
}

/// Which conversations are open as columns, per space, and which has focus.
@MainActor @Observable final class ColumnsModel {
    /// Kept across launches, so each space comes back with the columns it was left with.
    private var openBySpace: [String: [UUID]] = ColumnsModel.saved() {
        didSet { UserDefaults.standard.set(openBySpace.mapValues { $0.map(\.uuidString) }, forKey: Self.key) }
    }
    private static let key = "NoodlePrototypeColumns"

    private static func saved() -> [String: [UUID]] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return stored.mapValues { $0.compactMap(UUID.init(uuidString:)) }
    }

    var focusedID: UUID?
    var scrollTarget: UUID?
    /// A column whose input should take the keyboard, kept until that column exists to take it.
    var composerFocusTarget: (id: UUID, token: UUID)?

    func focusComposer(of id: UUID) { composerFocusTarget = (id, UUID()) }

    func open(in space: String?) -> [UUID] { openBySpace[space ?? ""] ?? [] }

    func show(_ id: UUID, in space: String?) {
        var ids = open(in: space)
        if !ids.contains(id) { ids.append(id) }
        openBySpace[space ?? ""] = ids
        focusedID = id
        scrollTarget = id
    }

    func close(_ id: UUID, in space: String?) -> UUID? {
        var ids = open(in: space)
        guard let index = ids.firstIndex(of: id) else { return focusedID }
        ids.remove(at: index)
        openBySpace[space ?? ""] = ids
        if focusedID == id { focusedID = ids.isEmpty ? nil : ids[min(index, ids.count - 1)] }
        return focusedID
    }

    func move(_ id: UUID, before target: UUID, in space: String?) {
        var ids = open(in: space)
        guard id != target, let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        ids.insert(id, at: ids.firstIndex(of: target) ?? ids.endIndex)
        openBySpace[space ?? ""] = ids
    }

    func step(_ offset: Int, in space: String?) -> UUID? {
        let ids = open(in: space)
        guard !ids.isEmpty else { return nil }
        let index = focusedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        return ids[(index + offset + ids.count) % ids.count]
    }
}

struct ConversationColumns: View {
    @Environment(NoodleStore.self) private var store
    @Bindable var model: ColumnsModel
    static let minimumWidth: CGFloat = 360
    /// Columns this far past either edge load their transcript. Loaded columns stay loaded, since
    /// loading costs far more than keeping one, until more than maxLoaded are; the farthest then become cards.
    static let loadedMargin = 1, maxLoaded = 12
    @State private var visible = 0..<0
    @State private var loaded: Set<Int> = []

    var body: some View {
        // A saved column whose conversation has since gone is left out.
        let ids = model.open(in: store.space).filter { store.conversation(withID: $0) != nil }
        ColumnsScrollView(store: store, model: model, ids: ids, loaded: loaded) { visible = $0 }
        .onChange(of: visible, initial: true) { updateLoaded(count: ids.count) }
        // A conversation chosen in the sidebar opens as a column, or scrolls to the one already open.
        .onChange(of: store.selectedConversationID, initial: true) { _, id in
            guard let id else { return }
            model.show(id, in: store.space)
            if NSApp.currentEventIsClick { model.focusComposer(of: id) }
        }
        .onChange(of: store.space) { _, space in
            // A space never used in Columns starts with its selected conversation.
            if let focused = model.open(in: space).first { store.selectedConversationID = focused }
            else if let id = store.selectedConversationID { model.show(id, in: space) }
        }
        .onChange(of: ids, initial: true) { updateLoaded(count: ids.count) }
        .overlay {
            if ids.isEmpty {
                ContentUnavailableView("No Columns", systemImage: "rectangle.split.3x1",
                    description: Text("Choose a conversation in the sidebar to open it as a column."))
            }
        }
        // Stand-ins for the menu shortcuts the PRD asks for.
        .background {
            Group {
                Button("") { close(model.focusedID) }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("") { focus(model.step(-1, in: store.space)) }.keyboardShortcut("[", modifiers: .command)
                Button("") { focus(model.step(1, in: store.space)) }.keyboardShortcut("]", modifiers: .command)
            }
            .opacity(0).accessibilityHidden(true)
        }
    }

    private func updateLoaded(count: Int) {
        let near = Set(max(0, visible.lowerBound - Self.loadedMargin)..<min(count, visible.upperBound + Self.loadedMargin))
        var next = loaded.filter { $0 < count }.union(near)
        if next.count > Self.maxLoaded {
            let center = Double(visible.lowerBound + visible.upperBound) / 2
            next = Set(next.sorted { abs(Double($0) - center) < abs(Double($1) - center) }.prefix(Self.maxLoaded))
        }
        if next != loaded { loaded = next }
    }


    private func close(_ id: UUID?) {
        guard let id else { return }
        store.selectedConversationID = model.close(id, in: store.space)
    }

    private func focus(_ id: UUID?) {
        guard let id else { return }
        model.show(id, in: store.space)
        store.selectedConversationID = id
    }
}

/// The columns in an AppKit scroll view. Scrolling moves only the clip view's bounds, so a column's
/// SwiftUI graph is not laid out again for every scrolled point, as it is inside a SwiftUI ScrollView.
private struct ColumnsScrollView: NSViewRepresentable {
    let store: NoodleStore
    let model: ColumnsModel
    let ids: [UUID]
    let loaded: Set<Int>
    let visibleChanged: (Range<Int>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SidewaysScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = FlippedView()
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollView = scrollView
        // Transcripts would reflow at every step of a drag of the window's edge; they take the new width once it ends.
        scrollView.liveResizeChanged = { [coordinator = context.coordinator] resizing in
            coordinator.frozenWidth = resizing ? coordinator.width : nil
            if !resizing { coordinator.layout() }
        }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged),
            name: NSView.frameDidChangeNotification, object: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.layout()
        if let target = model.scrollTarget, let index = ids.firstIndex(of: target) {
            DispatchQueue.main.async { model.scrollTarget = nil }
            coordinator.reveal(index)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ColumnsScrollView?
        weak var scrollView: NSScrollView?
        private var columns: [UUID: NSHostingView<AnyView>] = [:]
        private var shown: [UUID: Bool] = [:]
        private var lastVisible = 0..<0

        /// The width the columns had when a live resize began; they keep it until it ends.
        var frozenWidth: CGFloat?

        /// Columns share the area, each at most half of it, until they reach their minimum; past that,
        /// as many as fit whole share it, so the visible ones always meet both edges.
        var width: CGFloat {
            if let frozenWidth { return frozenWidth }
            guard let scrollView, let parent else { return ConversationColumns.minimumWidth }
            let available = scrollView.contentView.bounds.width
            let fitting = max(1, Int(available / ConversationColumns.minimumWidth))
            // Before the area has a size, available is zero.
            return max(ConversationColumns.minimumWidth, available / CGFloat(min(max(parent.ids.count, 2), fitting)))
        }

        func layout() {
            guard let parent, let scrollView, let document = scrollView.documentView else { return }
            let width = width, height = scrollView.contentView.bounds.height
            document.frame = NSRect(x: 0, y: 0, width: width * CGFloat(parent.ids.count), height: height)
            for id in Set(columns.keys).subtracting(parent.ids) {
                columns.removeValue(forKey: id)?.removeFromSuperview()
                shown[id] = nil
            }
            for (index, id) in parent.ids.enumerated() {
                let isLoaded = parent.loaded.contains(index)
                let content = AnyView(ColumnSlot(conversationID: id, model: parent.model, isLoaded: isLoaded).environment(parent.store))
                let view: NSHostingView<AnyView>
                if let existing = columns[id] {
                    view = existing
                    if shown[id] != isLoaded { view.rootView = content }
                } else {
                    view = NSHostingView(rootView: content)
                    view.sizingOptions = []
                    document.addSubview(view)
                    columns[id] = view
                }
                shown[id] = isLoaded
                // On whole pixels: a column at a fractional position draws its text and pictures blurred.
                let frame = document.backingAlignedRect(NSRect(x: CGFloat(index) * width, y: 0, width: width, height: height),
                    options: .alignAllEdgesNearest)
                if view.frame != frame { view.frame = frame }
            }
            boundsChanged()
        }

        @objc func boundsChanged() {
            guard let scrollView, let parent else { return }
            let bounds = scrollView.contentView.bounds, width = width
            if scrollView.documentView?.frame.height != bounds.height || abs((scrollView.documentView?.frame.width ?? 0) - width * CGFloat(parent.ids.count)) > 0.5 {
                // The area was resized: columns take their new widths.
                DispatchQueue.main.async { self.layout() }
                return
            }
            let first = max(0, Int(bounds.minX / width))
            let last = min(parent.ids.count, Int((bounds.maxX / width).rounded(.up)))
            let visible = first..<max(first, last)
            if visible != lastVisible {
                lastVisible = visible
                let report = parent.visibleChanged
                DispatchQueue.main.async { report(visible) }
            }
        }

        func reveal(_ index: Int) {
            guard let scrollView else { return }
            let width = width, bounds = scrollView.contentView.bounds
            let minX = CGFloat(index) * width
            var x = bounds.minX
            if minX < bounds.minX { x = minX } else if minX + width > bounds.maxX { x = minX + width - bounds.width }
            guard x != bounds.minX else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// Each column's transcript scrolls vertically and would take every swipe over it. A swipe that
    /// starts mostly sideways goes to the columns instead, with its momentum.
    private final class SidewaysScrollView: NSScrollView {
        private var monitor: Any?
        private var routing = false
        var liveResizeChanged: ((Bool) -> Void)?

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            liveResizeChanged?(true)
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            liveResizeChanged?(false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.route(event) else { return event }
                return nil
            }
        }

        private func route(_ event: NSEvent) -> Bool {
            guard event.window === window else { return false }
            let isWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
            if event.phase == .began || isWheel {
                let inside = bounds.contains(convert(event.locationInWindow, from: nil))
                routing = inside && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            guard routing else { return false }
            scrollWheel(with: event)
            if isWheel { routing = false }
            return true
        }
    }
}

/// Each column has a SwiftUI graph of its own, so an update in one column leaves the others alone.
private struct ColumnSlot: View {
    @Environment(NoodleStore.self) private var store
    let conversationID: UUID
    let model: ColumnsModel
    let isLoaded: Bool

    var body: some View {
        if let conversation = store.conversation(withID: conversationID) {
            ConversationColumn(conversation: conversation, model: model, isLoaded: isLoaded)
        }
    }
}

private struct ConversationColumn: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    @Bindable var model: ColumnsModel
    let isLoaded: Bool
    @State private var kickRequest: AgentKickRequest?
    @State private var isDropTargeted = false
    @State private var isReorderTargeted = false
    @State private var composerFocusRequest: UUID?

    private var isFocused: Bool { model.focusedID == conversation.id }

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(conversation: conversation, isFocused: isFocused, kickRequest: $kickRequest) {
                store.selectedConversationID = model.close(conversation.id, in: store.space)
            }
            .draggable(conversation.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                withAnimation(.smooth) { model.move(id, before: conversation.id, in: store.space) }
                return true
            } isTargeted: { isReorderTargeted = $0 }

            if isLoaded {
                AttachmentPreviewScope(conversationID: conversation.id) { preview in
                    ChatView(conversation: conversation, attachmentPreview: preview, composerFocusRequest: composerFocusRequest)
                }
            } else {
                ColumnCard(conversation: conversation)
            }
        }
        .background {
            let background = store.background(for: conversation)
            ConversationWallpaper(background: background,
                imageURL: store.repository.backgroundImageURL(background, conversationID: conversation.id))
        }
        .clipped()
        .overlay(alignment: .trailing) {
            Rectangle().fill(.separator).frame(width: 1).accessibilityHidden(true)
        }
        .overlay(alignment: .leading) {
            if isReorderTargeted {
                Rectangle().fill(Color.accentColor).frame(width: 3).allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2).padding(4)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            model.focusedID = conversation.id
            if store.selectedConversationID != conversation.id { store.selectedConversationID = conversation.id }
        })
        .onDrop(of: AttachmentTransfer.dropContentTypes, isTargeted: $isDropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            store.markConversationRead(conversation.id)
            store.importAttachments(from: providers, into: conversation.id)
            return true
        }
        .modifier(AgentKickConfirmation(store: store, request: $kickRequest))
        .onChange(of: model.composerFocusTarget?.token, initial: true) {
            guard let target = model.composerFocusTarget, target.id == conversation.id else { return }
            model.composerFocusTarget = nil
            DispatchQueue.main.async { composerFocusRequest = UUID() }
        }
    }
}

/// What a column far off screen shows instead of its transcript.
private struct ColumnCard: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation

    var body: some View {
        VStack(spacing: 10) {
            ConversationStatusAvatar(conversation: conversation, size: 56, dotSize: 12, ringWidth: 3)
            Text(store.title(for: conversation)).font(.title3.weight(.semibold))
            Text(store.preview(for: conversation))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ColumnHeader: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    let isFocused: Bool
    @Binding var kickRequest: AgentKickRequest?
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            ConversationStatusAvatar(conversation: conversation, size: 26, dotSize: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.title(for: conversation))
                    .font(.headline)
                    .lineLimit(1)
                Text(store.preview(for: conversation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            ConversationPauseControl(conversation: conversation, kickRequest: $kickRequest)
            Group {
                VoiceCallToolbarControl(conversation: conversation)
                ConversationCompanionsMenu(conversation: conversation)
                actionsMenu
                Button(action: close) { Label("Close Column", systemImage: "xmark") }
                    .help("Close Column")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.bar.opacity(isFocused ? 1 : 0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(isFocused ? Color.accentColor : Color(nsColor: .separatorColor))
                .frame(height: isFocused ? 2 : 1)
                .accessibilityHidden(true)
        }
        .onHover { isHovered = $0 }
    }

    private var actionsMenu: some View {
        Menu {
            if conversation.kind == .direct, let agent = store.participants(for: conversation).first {
                if !store.isShared(agent.id) { Button("Edit Bot…") { store.agentBeingEdited = agent } }
            } else if conversation.kind == .group {
                Button("Edit Group…") { store.groupBeingEdited = conversation }
            }
            Button("Change Background…") { store.backgroundBeingEdited = conversation }
            Divider()
            Button("Open in New Window") { store.dockConversation(conversation.id) }
            Button("Float on Top") { store.floatConversation(conversation.id) }
        } label: {
            Label("Conversation Info", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Conversation Info")
    }
}

/// View > Enter Full Screen, in place of the one AppKit appends right after the layouts.
struct FullScreenCommand: View {
    @State private var state = FullScreenState()

    var body: some View {
        Button(state.isFullScreen ? "Exit Full Screen" : "Enter Full Screen") {
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
        .keyboardShortcut("f", modifiers: [.control, .command])
    }
}

@MainActor @Observable private final class FullScreenState {
    var isFullScreen = false
    @ObservationIgnored private var observers: [Any] = []

    init() {
        let update: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { self.isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true }
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: update))
        }
    }
}

/// View > As List and As Columns.
struct MainWindowLayoutCommands: View {
    @AppStorage(MainWindowLayout.key) private var layout = MainWindowLayout.list

    var body: some View {
        Picker("Layout", selection: $layout) {
            Text("As List").tag(MainWindowLayout.list)
            Text("As Columns").tag(MainWindowLayout.columns)
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The open columns as pictures in the toolbar; choosing one brings its column into view.
struct ColumnSwitcher: View {
    @Environment(NoodleStore.self) private var store
    let model: ColumnsModel

    var body: some View {
        let conversations = model.open(in: store.space).compactMap(store.conversation(withID:))
        if !conversations.isEmpty {
            HStack(spacing: 4) {
                ForEach(conversations) { conversation in
                    let isFocused = model.focusedID == conversation.id
                    Button {
                        store.selectedConversationID = conversation.id
                        model.focusComposer(of: conversation.id)
                    } label: {
                        ConversationStatusAvatar(conversation: conversation, size: 24, dotSize: 7)
                            .padding(3)
                            .background(Circle().fill(isFocused ? Color.accentColor.opacity(0.35) : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(store.title(for: conversation))
                    .accessibilityLabel(store.title(for: conversation))
                    .accessibilityAddTraits(isFocused ? .isSelected : [])
                }
            }
            .padding(.horizontal, 6)
        }
    }
}
#endif
