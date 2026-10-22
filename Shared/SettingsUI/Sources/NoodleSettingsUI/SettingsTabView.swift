import SwiftUI

/// The tab view every settings window uses. Like Safari, a newly chosen tab is
/// hidden while the window resizes to it, and fades in once the window has its size.
public struct SettingsTabView<Selection: Hashable, Content: View>: View {
    @Binding private var selection: Selection
    @State private var revealed: Selection
    private let content: Content

    private static var resizeDuration: Duration { .milliseconds(220) }

    public init(selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        _selection = selection
        _revealed = State(initialValue: selection.wrappedValue)
        self.content = content()
    }

    public var body: some View {
        // SwiftUI keeps a closed Settings window and its content, which would go on following the
        // app's data, piling up observations for as long as the app runs. A closed window holds
        // an empty frame of the same size instead, so it opens again without resizing.
        Group {
            if isOpen { tabs } else { Color.clear.frame(width: openSize.width, height: openSize.height) }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { if isOpen { openSize = $0 } }
        .background(WindowOpenReader(isOpen: $isOpen))
    }

    @State private var isOpen = true
    @State private var openSize = CGSize.zero

    private var tabs: some View {
        // Compared in the same update that switches tabs, so the new tab never shows a frame early.
        let shown = revealed == selection
        return TabView(selection: $selection.animation(.easeInOut(duration: 0.22))) { content }
            // Scoped to the opacity: hiding is instant, revealing fades.
            .animation(shown ? .easeOut(duration: 0.15) : nil) { $0.opacity(shown ? 1 : 0) }
            .modifier(TopResizeAnchor())
            .settingsScrollIndicators(selection: selection)
            .task(id: selection) {
                guard revealed != selection else { return }
                do { try await Task.sleep(for: Self.resizeDuration) }
                catch { return }
                revealed = selection
            }
    }
}

/// Whether the window holding this view is open: false once it closes, true once it shows again.
private struct WindowOpenReader: NSViewRepresentable {
    @Binding var isOpen: Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.changed = { open in if isOpen != open { isOpen = open } }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.changed = { open in if isOpen != open { isOpen = open } }
    }

    final class ReaderView: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var closing: NSObjectProtocol?
        private var visibility: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closing.map(NotificationCenter.default.removeObserver)
            visibility = nil
            guard let window else { return }
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed(false) }
            }
            // Nothing is posted when a closed window is ordered in again.
            visibility = window.observe(\.isVisible) { [weak self] window, _ in
                MainActor.assumeIsolated { if window.isVisible { self?.changed(true) } }
            }
        }

        deinit { closing.map(NotificationCenter.default.removeObserver) }
    }
}

private struct TopResizeAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.windowResizeAnchor(.top) } else { content }
    }
}
