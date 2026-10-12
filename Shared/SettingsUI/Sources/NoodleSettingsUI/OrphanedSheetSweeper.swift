import AppKit

/// Takes away a sheet left on screen after the window it hung from went away.
/// Such a sheet takes no clicks, so its Cancel and Save did nothing and only
/// quitting removed it. How it got left behind was never reproduced.
@MainActor public final class OrphanedSheetSweeper: NSObject {
    public static let shared = OrphanedSheetSweeper()

    private let windows: () -> [NSWindow]
    private let delay: Duration
    private var pending: Task<Void, Never>?

    init(windows: @escaping () -> [NSWindow] = { NSApp.windows }, delay: Duration = .seconds(1)) {
        self.windows = windows
        self.delay = delay
        super.init()
    }

    public func start() {
        let center = NotificationCenter.default
        center.removeObserver(self)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification, NSApplication.didBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(windowsChanged), name: name, object: nil)
        }
    }

    public func stop() {
        NotificationCenter.default.removeObserver(self)
        pending?.cancel()
        pending = nil
    }

    // Sheets are briefly between windows while they slide in or out, so the sweep waits for that to finish.
    @objc private func windowsChanged(_ notification: Notification) {
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sweep()
        }
    }

    func sweep() {
        for sheet in windows() where Self.isOrphaned(sheet) {
            sheet.sheetParent?.endSheet(sheet)
            if sheet.isVisible { sheet.orderOut(nil) }
        }
    }

    /// A minimized window takes its sheets into the Dock, and a modal panel run on its own has no parent.
    static func isOrphaned(_ window: NSWindow) -> Bool {
        guard window.isSheet, window.isVisible, window !== NSApp.modalWindow else { return false }
        guard let parent = window.sheetParent else { return true }
        return !parent.isVisible && !parent.isMiniaturized
    }
}
