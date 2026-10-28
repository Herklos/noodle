import AppKit
import BrowserBridge
import BrowserCore
import WebKit
@testable import NoodleBrowser
import XCTest

final class BrowserPageLifetimeTests: XCTestCase {
    /// Closing a tab must break WebKit's script-handler ownership cycle, even while its browser stays open.
    @MainActor func testClosingTabsReleasesTheirPagesAndSurfaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Lifetime").id
        for _ in 0..<12 {
            weak var closedTab: BrowserTab?
            weak var closedWeb: WKWebView?
            weak var closedSurface: NSWindow?
            try autoreleasepool {
                let tab = try runtime.makeTab(browserID: browser)
                closedTab = tab; closedWeb = tab.web; closedSurface = tab.surface
                try runtime.closeTab(browserID: browser, tabID: tab.id)
            }
            XCTAssertNil(closedTab, "the runtime retained a closed tab")
            XCTAssertNil(closedWeb, "a closed tab retained its WebKit page")
            XCTAssertNil(closedSurface, "a closed tab retained its rendering surface")
        }
        XCTAssertTrue(runtime.tabs.isEmpty)
        XCTAssertTrue(try library.profile(browser).tabs.isEmpty)
    }

    /// Eviction keeps the saved tab, without retaining the page or the tab's rendering surface.
    @MainActor func testUnloadingATabReleasesItsPageAndSurface() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Lifetime").id
        weak var unloadedTab: BrowserTab?
        weak var unloadedWeb: WKWebView?
        weak var unloadedSurface: NSWindow?
        let unloadedID = try autoreleasepool {
            let tab = try runtime.makeTab(browserID: browser)
            unloadedTab = tab; unloadedWeb = tab.web; unloadedSurface = tab.surface
            tab.lastActive = .distantPast
            for _ in 0..<BrowserLimits.runningPages { _ = try runtime.makeTab(browserID: browser) }
            return tab.id
        }
        XCTAssertNil(runtime.tabs[unloadedID])
        XCTAssertTrue(try library.profile(browser).tabs.contains { $0.id == unloadedID })
        XCTAssertNil(unloadedTab, "the runtime retained an unloaded tab")
        XCTAssertNil(unloadedWeb, "an unloaded tab retained its WebKit page")
        XCTAssertNil(unloadedSurface, "an unloaded tab retained its rendering surface")
    }

    @MainActor func testShutdownReleasesPagesWhileRuntimeIsRetained() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        let browser = try library.create(name: "Lifetime").id
        weak var stoppedTab: BrowserTab?
        weak var stoppedWeb: WKWebView?
        weak var stoppedSurface: NSWindow?
        try autoreleasepool {
            let tab = try runtime.makeTab(browserID: browser)
            stoppedTab = tab; stoppedWeb = tab.web; stoppedSurface = tab.surface
            runtime.shutdown()
        }
        XCTAssertNil(stoppedTab)
        XCTAssertNil(stoppedWeb)
        XCTAssertNil(stoppedSurface)
        XCTAssertTrue(runtime.tabs.isEmpty)
    }

    /// Exercise a real page operation as well as construction: WebKit callbacks must not leave the closed tab owned.
    @MainActor func testClosingAScriptedPageReleasesItsTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Lifetime").id
        weak var closedTab: BrowserTab?
        func useAndClose() async throws {
            let opened = try await runtime.perform(.init(.open, browserID: browser))
            let id = try XCTUnwrap(opened.tabID)
            let tab = try runtime.tab(browserID: browser, tabID: id)
            closedTab = tab
            let size = try await tab.evaluate("window.payload = new Uint8Array(1 << 20); window.payload.fill(7); return window.payload.byteLength;")
            XCTAssertEqual(size as? Int, 1 << 20)
            try runtime.closeTab(browserID: browser, tabID: id)
        }
        try await useAndClose()
        XCTAssertNil(closedTab, "a completed page operation retained the closed tab")
        XCTAssertTrue(runtime.tabs.isEmpty)
    }
}
