import AppKit
import SwiftUI

public extension View {
    /// Every sheet uses this. Like the settings windows, the sheet fits its
    /// content but never runs off the screen (taller content scrolls), and when
    /// it changes size the content hides, the sheet animates to its new size and
    /// the content fades back in.
    func noodleSheetSizing() -> some View {
        modifier(ScreenBoundSheet())
    }
}

extension View {
    func noodleSheetSizing(maxHeight: CGFloat?) -> some View {
        modifier(SheetSizing(maxHeight: maxHeight))
    }
}

private struct ScreenBoundSheet: ViewModifier {
    @State private var maxHeight: CGFloat? = SettingsScreenObserver.availableHeight(in: nil)

    func body(content: Content) -> some View {
        content
            .noodleSheetSizing(maxHeight: maxHeight)
            .background {
                SettingsScreenObserver { height in
                    if maxHeight != height { maxHeight = height }
                }
            }
    }
}

private struct SheetSizing: ViewModifier {
    let maxHeight: CGFloat?
    @State private var measured: CGSize?
    @State private var shown = true

    func body(content: Content) -> some View {
        SettingsContentHeight(maxHeight: maxHeight) { content }
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                // Hide in the same update that changes the size, so the content
                // never shows clipped by the old frame. Typing that grows a field
                // keeps the field visible.
                if let measured, !SheetSizeView.matches(measured, size), !SheetSizeView.isTyping() {
                    shown = false
                }
                measured = size
            }
            .background {
                SheetContentSizeBridge(contentSize: measured) { shown = true }
            }
            // Scoped to the opacity: hiding is instant, revealing fades.
            .animation(shown ? .easeOut(duration: 0.15) : nil) { $0.opacity(shown ? 1 : 0) }
            .scrollBounceBehavior(.basedOnSize)
            .settingsScrollIndicators(selection: 0)
            // Keep the scrollbar clear of the sheet's rounded corners.
            .contentMargins(.vertical, 16, for: .scrollIndicators)
            .presentationSizing(.fitted)
    }
}

// macOS can retain a sheet's initial window size even after SwiftUI's ideal
// content size changes. Keep the actual sheet in sync, without recreating the
// editor (which would lose drafts, focus and nested presentation state).
private struct SheetContentSizeBridge: NSViewRepresentable {
    let contentSize: CGSize?
    let onSettled: () -> Void

    func makeNSView(context: Context) -> SheetSizeView { SheetSizeView() }

    func updateNSView(_ view: SheetSizeView, context: Context) {
        view.onSettled = onSettled
        guard let contentSize else { return }
        view.contentSize = contentSize
        view.scheduleResize()
    }
}

private final class SheetSizeView: NSView {
    private static var resizeDuration: TimeInterval { 0.22 }

    var contentSize = CGSize.zero
    var onSettled: (() -> Void)?
    private var resizeScheduled = false
    private var sized = false
    private var generation = 0

    @MainActor static func matches(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }

    @MainActor static func isTyping() -> Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sized = false
        scheduleResize()
    }

    func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        // Resize outside SwiftUI's layout pass and coalesce intermediate
        // measurements from the same update.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resize()
        }
    }

    private func resize() {
        generation &+= 1
        guard let window, window.sheetParent != nil,
              contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0 else { return settle() }
        let size = NSSize(width: ceil(contentSize.width), height: ceil(contentSize.height))
        let current = window.contentRect(forFrameRect: window.frame).size
        guard !Self.matches(current, size) else { return settle() }
        guard sized, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            sized = true
            window.setContentSize(size)
            return settle()
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        // Keep the sheet attached at its top edge while its body changes.
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        let generation = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            // A newer size takes over; it reveals the content when it lands.
            guard let self, self.generation == generation else { return }
            self.settle()
        }
    }

    private func settle() {
        sized = sized || window != nil
        onSettled?()
    }
}
