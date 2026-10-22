import AppKit
import BrowserBridge
import BrowserCore
import SwiftUI
@testable import NoodleBrowser
import XCTest

final class BrowserWebViewTests: XCTestCase {
    /// Switching browsers and back can tear down the view left behind after the returning one took the page.
    @MainActor func testTearingDownAViewLeftBehindKeepsThePageWhereItWent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: try library.create(name: "Work").id)
        let left = BrowserWebContainer(web: tab.web), returning = BrowserWebContainer(web: tab.web)
        BrowserWebView.dismantleNSView(left, coordinator: tab)
        XCTAssertTrue(tab.web.superview === returning)
        BrowserWebView.dismantleNSView(returning, coordinator: tab)
        XCTAssertTrue(tab.web.window === tab.surface)
    }

    /// A tab out of the browser window keeps its page in a window of its own that nobody at this
    /// Mac sees. Only a live view puts it on screen, transparent; nothing else can show it.
    @MainActor func testATabsOwnWindowStaysOffScreenUnlessWatched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: try library.create(name: "Work").id)
        defer { tab.surface.orderOut(nil) }
        XCTAssertTrue(tab.web.window === tab.surface)
        let attempts: [(String, () -> Void)] = [
            ("orderFront", { tab.surface.orderFront(nil) }), ("orderBack", { tab.surface.orderBack(nil) }),
            ("makeKeyAndOrderFront", { tab.surface.makeKeyAndOrderFront(nil) }),
            ("orderFrontRegardless", { tab.surface.orderFrontRegardless() }), ("setIsVisible", { tab.surface.setIsVisible(true) }),
        ]
        for (name, show) in attempts {
            show()
            XCTAssertFalse(tab.surface.isVisible, "\(name) showed the tab's window")
            tab.surface.orderOut(nil)
        }

        tab.watched = true
        XCTAssertTrue(tab.surface.isVisible)
        XCTAssertEqual(tab.surface.alphaValue, 0)
        XCTAssertTrue(tab.surface.ignoresMouseEvents)
        tab.watched = false
        XCTAssertFalse(tab.surface.isVisible)
        XCTAssertEqual(tab.surface.alphaValue, 1)
    }

    /// A tab a bot uses keeps drawing and getting animation frames with no browser window open,
    /// as if seen, without showing on this Mac. Sites that wait for a frame before showing
    /// anything, such as X's profile editor, otherwise stay empty for bots.
    @MainActor func testATabABotUsesKeepsDrawingWithNoWindowOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work").id
        let opened = try await runtime.perform(.init(.open, browserID: browser))
        let tabID = try XCTUnwrap(opened.tabID)
        var start = BrowserRequest(.eval, browserID: browser, tabID: tabID)
        start.text = "window.ticks = 0; (function tick() { ticks++; requestAnimationFrame(tick); })(); return true;"
        _ = try await runtime.perform(start)
        let tab = try runtime.tab(browserID: browser, tabID: tabID)
        var ticks = 0
        for _ in 0..<100 where ticks < 20 {
            try await Task.sleep(for: .milliseconds(100))
            ticks = try await tab.evaluate("return ticks;") as? Int ?? 0
        }
        XCTAssertGreaterThanOrEqual(ticks, 20, "animation frames stalled in a tab nobody has open")
        let visibility = try await tab.evaluate("return document.visibilityState;") as? String
        XCTAssertEqual(visibility, "visible")
        XCTAssertTrue(tab.web.window === tab.surface)
        XCTAssertTrue(!tab.surface.isVisible || (tab.surface.alphaValue == 0 && tab.surface.ignoresMouseEvents),
                      "the tab's page showed on this Mac")
    }

    /// A tab rests again once the bot stops using it, so tabs bots left behind cost nothing; and
    /// while a person watches the browser live, only the tab they see draws.
    @MainActor func testATabRestsWhenTheBotStopsUsingItOrAPersonWatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        runtime.agentAttention = .milliseconds(300)
        let browser = try library.create(name: "Work").id
        let opened = try await runtime.perform(.init(.open, browserID: browser))
        let tabID = try XCTUnwrap(opened.tabID)
        let tab = try runtime.tab(browserID: browser, tabID: tabID)
        // WebKit tells the page whether it is seen a moment after its window comes or goes.
        func becomes(_ state: String) async throws -> Bool {
            for _ in 0..<100 {
                if try await tab.evaluate("return document.visibilityState;") as? String == state { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        XCTAssertTrue(tab.attended)
        for _ in 0..<100 where tab.attended { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(tab.attended, "the tab kept drawing after the bot stopped using it")
        XCTAssertFalse(tab.surface.isVisible)
        let rested = try await becomes("hidden")
        XCTAssertTrue(rested, "the page still counts as seen after the bot stopped using it")

        runtime.agentAttention = .seconds(300)
        var use = BrowserRequest(.eval, browserID: browser, tabID: tabID); use.text = "return true;"
        _ = try await runtime.perform(use)
        XCTAssertTrue(tab.attended)
        let drawing = try await becomes("visible")
        XCTAssertTrue(drawing, "a tab the bot used again stayed out of sight")
        let seen = try runtime.makeTab(browserID: browser)
        runtime.showWatchedTab(browser, watched: true)
        XCTAssertFalse(tab.attended, "a bot's tab kept drawing while a person watched another")
        XCTAssertFalse(tab.surface.isVisible)
        XCTAssertTrue(seen.watched)
        let hiddenWhileWatched = try await becomes("hidden")
        XCTAssertTrue(hiddenWhileWatched, "a bot's page still counts as seen while a person watches another")
    }

    /// A tab's own window turns opaque only once it is off screen, so a bot's tab resting, moving
    /// or closing never flashes its page, or an empty window, on this Mac.
    @MainActor func testATabsOwnWindowNeverShowsOpaqueOnScreen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work").id
        let tab = try runtime.makeTab(browserID: browser)
        defer { tab.surface.orderOut(nil) }
        var shown: [String] = [], step = ""
        let observation = tab.surface.observe(\.alphaValue, options: [.new]) { surface, _ in
            MainActor.assumeIsolated { if surface.isVisible && surface.alphaValue > 0 { shown.append(step) } }
        }
        defer { observation.invalidate() }
        step = "attention ending"; tab.attend(for: .seconds(300)); tab.endAttention()
        step = "live view ending"; tab.watched = true; tab.watched = false
        step = "moving into a browser window"; tab.attend(for: .seconds(300))
        let container = BrowserWebContainer(web: tab.web)
        step = "moving back"; BrowserWebView.dismantleNSView(container, coordinator: tab)
        step = "closing"; try runtime.closeTab(browserID: browser, tabID: tab.id)
        XCTAssertEqual(shown, [], "the tab's window was on screen while opaque")
    }

    /// A bot that fills a browser with tabs is told how to make room, and nothing is shown to the person.
    @MainActor func testABotAtTheTabLimitIsToldToCloseTabs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work").id
        var profile = try library.profile(browser)
        profile.tabs = (0..<100).map { _ in BrowserTabInfo(lastUsed: Date()) }
        try library.update(profile)
        do {
            _ = try await runtime.perform(.init(.open, browserID: browser))
            XCTFail("a bot opened a tab past the limit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("(tabs, close)"), error.localizedDescription)
        }
        XCTAssertNil(runtime.failure, "the person was alerted to a bot's tab")
    }

    /// A page a bot drives that opens a window past the tab limit tells the bot on its tab, not the person.
    @MainActor func testAPopupPastTheTabLimitInABotsTabTellsTheBot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work").id
        let opened = try await runtime.perform(.init(.open, browserID: browser))
        let tabID = try XCTUnwrap(opened.tabID)
        var profile = try library.profile(browser)
        profile.tabs += (0..<99).map { _ in BrowserTabInfo(lastUsed: Date()) }
        try library.update(profile)
        var popup = BrowserRequest(.eval, browserID: browser, tabID: tabID)
        popup.text = "return window.open('about:blank') === null;"
        let response = try await runtime.perform(popup)
        XCTAssertEqual(response.text, "true")
        XCTAssertNil(runtime.failure, "the person was alerted to a bot's popup")
        let tab = try runtime.tab(browserID: browser, tabID: tabID)
        XCTAssertTrue(tab.info.error?.contains("(tabs, close)") == true, tab.info.error ?? "no note on the tab")
    }

    /// A bot's script or click that fails in the page says why, in the page's words, instead of
    /// WebKit's "A JavaScript exception occurred".
    @MainActor func testFailedPageScriptsSayWhy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work").id
        let opened = try await runtime.perform(.init(.open, browserID: browser))
        let tabID = try XCTUnwrap(opened.tabID)
        func failure(_ request: BrowserRequest) async -> String? {
            do { _ = try await runtime.perform(request); return nil } catch { return error.localizedDescription }
        }
        var click = BrowserRequest(.click, browserID: browser, tabID: tabID); click.target = "#missing"
        let clicked = await failure(click)
        XCTAssertEqual(clicked, "Element not found")
        var eval = BrowserRequest(.eval, browserID: browser, tabID: tabID)
        eval.text = "const editor = null;\nreturn editor.fields;"
        let evaluated = await failure(eval)
        XCTAssertTrue(evaluated?.hasPrefix("TypeError: null is not an object") == true, evaluated ?? "no error")
    }

    /// Switching tabs and back leaves a page where the person scrolled it, also while a bot uses
    /// the tab, when its own window is put on screen out of sight each time it leaves the browser
    /// window.
    @MainActor func testSwitchingTabsKeepsTheScrollPositionOfATabABotUses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work").id
        let opened = try await runtime.perform(.init(.open, browserID: browser))
        let tab = try runtime.tab(browserID: browser, tabID: try XCTUnwrap(opened.tabID))
        let other = try runtime.makeTab(browserID: browser)
        XCTAssertTrue(tab.attended)
        func until(_ condition: () async throws -> Bool) async throws -> Bool {
            for _ in 0..<100 {
                if try await condition() { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        let page = "<!doctype html><title>Long</title><body style='min-height:3000px'><input id=name></body>"
        for loading in [tab, other] { loading.web.loadHTMLString(page, baseURL: URL(string: "https://example.com/")) }
        let loaded = try await until {
            for loading in [tab, other] where try await loading.evaluate("return document.readyState==='complete' && !!document.querySelector('#name');") as? Bool != true { return false }
            return true
        }
        XCTAssertTrue(loaded, "pages did not load")
        // As in the browser window, which the person may have closed meanwhile.
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let presentation = BrowserPresentation(library: library, runtime: runtime, defaults: nil)
        presentation.selection = browser; presentation.selectTab(tab.id)
        let host = NSHostingView(rootView: BrowserLibraryView(presentation: presentation))
        window.contentView = host; host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
        let mounted = try await until { tab.web.window === window }
        XCTAssertTrue(mounted, "the tab never reached the browser window")
        try await Task.sleep(for: .milliseconds(300))
        _ = try await tab.evaluate("scrollTo(0,500); return true;")
        let scrolled = try await until { try await tab.evaluate("return scrollY===500;") as? Bool == true }
        XCTAssertTrue(scrolled, "the page did not scroll")
        for _ in 0..<3 {
            presentation.selectTab(other.id)
            let away = try await until { tab.web.window === tab.surface && other.web.window === window }
            XCTAssertTrue(away, "switching away did not move the pages")
            XCTAssertTrue(tab.attended && tab.surface.isVisible && tab.surface.alphaValue == 0, "the bot's tab stopped drawing out of sight")
            try await Task.sleep(for: .milliseconds(100))
            presentation.selectTab(tab.id)
            let back = try await until { tab.web.window === window }
            XCTAssertTrue(back, "switching back did not move the page")
            try await Task.sleep(for: .milliseconds(100))
        }
        let scroll = try await tab.evaluate("return scrollY;") as? Int
        XCTAssertEqual(scroll, 500, "switching tabs lost the scroll position")
    }

    /// A page that cannot load, or whose process stopped, gives way to an error page that says
    /// what went wrong; a load that fails after the page appeared leaves the page in place.
    @MainActor func testFailedPagesShowAnErrorPage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: try library.create(name: "Work").id)
        tab.webViewWebContentProcessDidTerminate(tab.web)
        XCTAssertEqual(tab.failure?.title, "This page stopped working")
        XCTAssertNotNil(tab.info.error)
        tab.navigate(try XCTUnwrap(URL(string: "about:blank")))
        XCTAssertNil(tab.failure)
        tab.webView(tab.web, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertEqual(tab.failure?.title, "No internet connection")
        tab.navigate(try XCTUnwrap(URL(string: "about:blank")))
        tab.webView(tab.web, didFail: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        XCTAssertNil(tab.failure)
        XCTAssertNotNil(tab.info.error)
        tab.webView(tab.web, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertNil(tab.failure)

        let site = URL(string: "https://example.com/news")
        XCTAssertEqual(BrowserPageFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost), url: site).detail,
                       "The server address of example.com could not be found.")
        XCTAssertEqual(BrowserPageFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted), url: site).title,
                       "Can't connect securely")
    }

    /// Sites serve their full pages only to browsers they recognise, and tabs out of sight run
    /// slower, as in Safari, so dozens of open tabs do not keep working at full speed.
    @MainActor func testTabsPassAsSafariAndSlowDownOutOfSight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: try library.create(name: "Work").id)
        let value = try await tab.web.evaluateJavaScript("navigator.userAgent")
        let agent = try XCTUnwrap(value as? String)
        XCTAssertNotNil(agent.range(of: #"Version/\d+(\.\d+)* Safari/605\.1\.15$"#, options: .regularExpression), agent)
        XCTAssertEqual(tab.web.configuration.preferences.inactiveSchedulingPolicy, .throttle)
    }

    /// A tab shows the page's own icon: one that fits a tab, a scalable one before any other, and
    /// the site's favicon.ico when the page names none.
    func testATabPicksThePagesIconThatFitsATab() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/news/today"))
        func link(_ rel: String, _ href: String, sizes: String = "", type: String = "") -> [String: String] {
            ["rel": rel, "href": href, "sizes": sizes, "type": type]
        }
        let sized = [link("icon", "https://example.com/16.png", sizes: "16x16"), link("icon", "https://example.com/32.png", sizes: "32x32"),
                     link("icon", "https://example.com/96.png", sizes: "96x96"), link("apple-touch-icon", "https://example.com/180.png")]
        XCTAssertEqual(BrowserFavicon.choose(sized, page: page)?.absoluteString, "https://example.com/32.png")
        XCTAssertEqual(BrowserFavicon.choose(sized + [link("icon", "https://example.com/i.svg", sizes: "any", type: "image/svg+xml"),
                                                      link("icon", "https://example.com/plain.svg")],
                                             page: page)?.absoluteString, "https://example.com/32.png",
                       "an SVG icon would be decoded outside WebKit's sandbox")
        XCTAssertEqual(BrowserFavicon.choose([link("apple-touch-icon", "https://example.com/180.png")], page: page)?.absoluteString,
                       "https://example.com/180.png", "a touch icon is better than none")
        XCTAssertEqual(BrowserFavicon.choose([link("shortcut icon", "/old.ico")], page: page)?.absoluteString, "https://example.com/old.ico")
        XCTAssertEqual(BrowserFavicon.choose([link("icon", "javascript:alert(1)")], page: page)?.absoluteString,
                       "https://example.com/favicon.ico", "an icon that is not an image address was used")
        XCTAssertEqual(BrowserFavicon.choose([], page: page)?.absoluteString, "https://example.com/favicon.ico")
        XCTAssertNil(BrowserFavicon.choose([], page: try XCTUnwrap(URL(string: "about:blank"))))
    }

    /// Icons are decoded in the app, outside WebKit's sandbox, so only small raster images are read,
    /// and an endless response is cut off instead of filling memory.
    func testIconsAreSmallRasterImagesReadNoFurtherThanTheLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IconServer.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let png = try XCTUnwrap(URL(string: "https://icons.test/icon.png")), svg = try XCTUnwrap(URL(string: "https://icons.test/icon.svg"))
        let endless = try XCTUnwrap(URL(string: "https://icons.test/endless"))
        let icon = await BrowserFavicon.load(png, using: session)
        XCTAssertEqual(icon?.size.width, 16)
        let vector = await BrowserFavicon.load(svg, using: session)
        XCTAssertNil(vector, "an SVG was decoded")
        let huge = await BrowserFavicon.load(endless, using: session)
        XCTAssertNil(huge)
        XCTAssertLessThan(IconServer.endlessBytesSent, 8 << 20, "the endless response was read to the end")
    }

    /// A link that downloads a file leaves the page where it was, so the tab shows no load error.
    @MainActor func testALinkThatDownloadsLeavesNoErrorOnTheTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work").id
        let tab = try runtime.makeTab(browserID: browser)
        tab.navigate(try XCTUnwrap(URL(string: "data:application/octet-stream;base64,\(Data("fixture".utf8).base64EncodedString())")))
        func finished() -> Bool { (try? library.profile(browser).downloads.first?.state) == "complete" }
        for _ in 0..<200 where !finished() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(finished(), "the download did not finish")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(tab.info.error)
    }
}

/// Serves `icons.test`: a 16-pixel PNG, an SVG, and an endless body sent in chunks until the load stops.
private final class IconServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var endlessBytesSent = 0
    private let stopped = NSLock(), queue = DispatchQueue(label: "icon-server")
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "icons.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch url.path {
        case "/icon.png":
            let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            client?.urlProtocol(self, didLoad: rep.representation(using: .png, properties: [:])!)
            client?.urlProtocolDidFinishLoading(self)
        case "/icon.svg":
            let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="red"/></svg>"#
            client?.urlProtocol(self, didLoad: Data(svg.utf8))
            client?.urlProtocolDidFinishLoading(self)
        default:
            Self.endlessBytesSent = 0
            queue.async { [self] in
                let chunk = Data(count: 64 << 10)
                while Self.endlessBytesSent < 64 << 20, !stopped.withLock({ isStopped }) {
                    client?.urlProtocol(self, didLoad: chunk); Self.endlessBytesSent += chunk.count
                    usleep(200)
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { stopped.withLock { isStopped = true } }
}
