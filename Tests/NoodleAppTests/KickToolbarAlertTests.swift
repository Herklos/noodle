import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

/// The Kick alert of a paused bot, pressed from the real window toolbar (#189). A bot waiting
/// for sign-in gets Sign In… there instead, so these use a usage limit, whose alert works the same way.
@MainActor final class KickToolbarAlertTests: HiddenViewTests {
    private func window<V: View>(_ view: V, width: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        let controller = NSHostingController(rootView: view)
        // As in the app's scenes: the view's toolbar becomes the window's NSToolbar.
        controller.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: 80, y: 80, width: width, height: 700), display: false)
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            for sheet in window.sheets { window.endSheet(sheet) }
            window.close(); window.contentViewController = nil
            NSApp.accessibilitySetValue(previous, forAttribute: enhanced)
        }
        return window
    }

    private func alerts() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible && descendants(window.contentView).contains {
                ($0 as? NSTextField)?.stringValue.hasPrefix("Usage limit reached") == true
            }
        }
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    private func describeAlerts(_ window: NSWindow) -> String {
        alerts().map { alert in
            "\(type(of: alert)) sheet=\(window.sheets.contains(alert)) parent=\(alert.sheetParent.map { "\($0.title)" } ?? "none") modal=\(NSApp.modalWindow === alert)"
        }.joined(separator: "; ")
    }

    private func assertEveryButtonDismisses(in window: NSWindow, store: NoodleStore,
                                            fixture: StoreFixture, agent: AgentRecord) async throws {
        let frame = try XCTUnwrap(window.contentView?.superview)
        for title in ["Cancel", "Retry Now"] {
            let kick = try await control("Kick", in: frame)
            press(kick)
            try await wait { !self.alerts().isEmpty }
            let shown = alerts()
            print("Kick alert after pressing Kick (\(title)): \(describeAlerts(window))")
            XCTAssertEqual(shown.count, 1, "One alert: \(describeAlerts(window))")
            XCTAssertTrue(window.sheets.contains { shown.contains($0) },
                          "The alert must be a sheet on its window, not app-modal: \(describeAlerts(window))")
            let alert = try XCTUnwrap(shown.first)
            let button = try XCTUnwrap(descendants(alert.contentView).compactMap { $0 as? NSButton }.first { $0.title == title }, title)
            button.performClick(nil)
            for _ in 0..<100 where !alerts().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(alerts().isEmpty, "\(title) brought the alert back: \(describeAlerts(window))")
            XCTAssertNil(NSApp.modalWindow, "\(title) left Noodle behind a modal window")
            for settings in NSApp.windows where settings !== window && settings.isVisible && !alerts().contains(settings) {
                settings.close()
            }
            if title == "Retry Now" {
                // The harness is still out of usage: the bot waits again, and nothing presents the alert by itself.
                let restarted = try XCTUnwrap(fixture.runtime.factory.processes.last)
                restarted.transition(.failed, failure: .usageLimit)
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertTrue(alerts().isEmpty, "The alert returned by itself after a failed retry")
            }
        }
    }

    func testMainWindowToolbarKickAlertIsASheetThatEveryButtonDismisses() async throws {
        let f = try fixture()
        try f.runtime.start(f.a).transition(.failed, failure: .usageLimit)
        f.store.selectedConversationID = f.directA.id
        let window = window(RootView().environment(f.store), width: 1160)
        try await assertEveryButtonDismisses(in: window, store: f.store, fixture: f, agent: f.a)
    }

    func testConversationWindowToolbarKickAlertIsASheetThatEveryButtonDismisses() async throws {
        let f = try fixture()
        try f.runtime.start(f.a).transition(.failed, failure: .usageLimit)
        let window = window(ConversationWindowView(conversationID: f.directA.id).environment(f.store), width: 760)
        try await assertEveryButtonDismisses(in: window, store: f.store, fixture: f, agent: f.a)
    }

    /// A bot waiting for sign-in offers Sign In… in the toolbar instead of Kick, which could not help.
    func testToolbarOffersSignInInsteadOfKickWhileTheBotWaitsForSignIn() async throws {
        let f = try fixture()
        try f.runtime.start(f.a).transition(.failed, failure: .authenticationRequired)
        let window = window(ConversationWindowView(conversationID: f.directA.id).environment(f.store), width: 760)
        let frame = try XCTUnwrap(window.contentView?.superview)
        _ = try await control("Sign In…", in: frame)
        XCTAssertFalse(elements(frame).contains { matches("Kick", node: $0) }, "Kick shows beside Sign In…")
    }
}
