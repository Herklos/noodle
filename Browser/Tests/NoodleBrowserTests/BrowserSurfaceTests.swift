import AppKit
import BrowserBridge
import BrowserCore
@testable import NoodleBrowser
import XCTest

final class BrowserSurfaceTests: XCTestCase {
    /// A tab's own window stays transparent through every change in a bot's use of the tab: the bot
    /// starting and going on, the tab moving into a browser window and back with its scroll position,
    /// a popup from the bot's page, a live view, the bot stopping and the tab closing. Its state is read
    /// from AppKit and from the window server, before and after each change of transparency and after
    /// each step, since the window server can apply an order-out later than a change of transparency.
    @MainActor func testATabsOwnWindowStaysTransparentThroughEveryChangeOfAttention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work").id
        var step = "", seen: [String] = [], observations: [NSKeyValueObservation] = [], observed = Set<ObjectIdentifier>()
        func server(_ window: NSWindow) -> (onScreen: Bool, alpha: Double)? {
            guard window.windowNumber > 0,
                  let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]])?.first
            else { return nil }
            return (info[kCGWindowIsOnscreen as String] as? Bool ?? false, (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
        func check(_ surface: NSWindow, _ moment: String) {
            var problems: [String] = []
            if surface.alphaValue > 0 { problems.append(surface.isVisible ? "on screen and opaque" : "opaque off screen") }
            if let state = server(surface), state.onScreen, state.alpha > 0 { problems.append("opaque on screen in the window server") }
            if !problems.isEmpty { seen.append("\(step) (\(moment)): \(problems.joined(separator: ", "))") }
        }
        func sample() {
            // Nor may a page put up a window of its own, such as a form's validation message.
            for other in NSApp.windows where other.isVisible && other.alphaValue > 0 && !(other is BrowserSurfacePanel) {
                seen.append("\(step): \(type(of: other)) on screen, child of \(other.parent.map { String(describing: type(of: $0)) } ?? "nothing")")
            }
            for tab in runtime.tabs.values {
                check(tab.surface, "after")
                guard observed.insert(ObjectIdentifier(tab.surface)).inserted else { continue }
                observations.append(tab.surface.observe(\.alphaValue, options: [.prior, .new]) { surface, change in
                    MainActor.assumeIsolated { check(surface, change.isPrior ? "before a change of transparency" : "after a change of transparency") }
                })
            }
        }
        defer { observations.forEach { $0.invalidate() } }
        func until(_ condition: () async throws -> Bool) async throws -> Bool {
            for _ in 0..<100 {
                if try await condition() { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        step = "a new tab"; let quiet = try runtime.makeTab(browserID: browser); sample()
        step = "a bot opening a tab"
        let opened = try await runtime.perform(.init(.open, browserID: browser))
        let tab = try runtime.tab(browserID: browser, tabID: try XCTUnwrap(opened.tabID)); sample()
        XCTAssertTrue(tab.attended && tab.surface.isVisible, "the bot's tab is not drawing out of sight")
        tab.web.loadHTMLString("<!doctype html><body style='min-height:3000px'>Long</body>", baseURL: URL(string: "https://example.com/"))
        let loaded = try await until { try await tab.evaluate("return document.readyState === 'complete' && document.body.textContent === 'Long';") as? Bool == true }
        XCTAssertTrue(loaded, "the page did not load")
        step = "a form's validation message in the bot's page"
        var invalid = BrowserRequest(.eval, browserID: browser, tabID: tab.id)
        invalid.text = "const form = document.createElement('form'); form.innerHTML = '<input required>'; document.body.prepend(form); return form.reportValidity();"
        _ = try await runtime.perform(invalid); sample()
        try await Task.sleep(for: .milliseconds(500)); sample()
        step = "the bot going on"
        var scroll = BrowserRequest(.eval, browserID: browser, tabID: tab.id); scroll.text = "scrollTo(0, 500); return scrollY;"
        _ = try await runtime.perform(scroll); sample()

        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        for round in 1...3 {
            step = "moving into a browser window, round \(round)"
            tab.detachSurface(); let container = BrowserWebContainer(web: tab.web); window.contentView = container; sample()
            step = "moving back, round \(round)"
            BrowserWebView.dismantleNSView(container, coordinator: tab); window.contentView = nil; sample()
            // The scroll position goes back as the page starts drawing again.
            try await Task.sleep(for: .milliseconds(100)); sample()
        }

        step = "a popup from the bot's page"
        var popup = BrowserRequest(.eval, browserID: browser, tabID: tab.id); popup.text = "return window.open('about:blank') !== null;"
        let popped = try await runtime.perform(popup); sample()
        XCTAssertEqual(popped.text, "true")
        step = "a live view starting"; runtime.showWatchedTab(browser, watched: true); sample()
        step = "a live view ending"; runtime.showWatchedTab(browser, watched: false); sample()

        step = "the bot using the tab again"; runtime.agentAttention = .milliseconds(200)
        var use = BrowserRequest(.eval, browserID: browser, tabID: tab.id); use.text = "return true;"
        _ = try await runtime.perform(use); sample()
        step = "the bot stopping"
        let rested = try await until { !tab.attended }; sample()
        XCTAssertTrue(rested, "the tab kept drawing after the bot stopped")
        XCTAssertFalse(tab.surface.isVisible)
        step = "attention ending at once"; tab.attend(for: .seconds(300)); sample(); tab.endAttention(); sample()
        step = "a bot's tab closing"; tab.attend(for: .seconds(300)); try runtime.closeTab(browserID: browser, tabID: tab.id); sample()
        step = "a quiet tab closing"; check(quiet.surface, "before"); try runtime.closeTab(browserID: browser, tabID: quiet.id); check(quiet.surface, "after")
        XCTAssertEqual(seen, [], "a tab's own window was not transparent")
    }
}
