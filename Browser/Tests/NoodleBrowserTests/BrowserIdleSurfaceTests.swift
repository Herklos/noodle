import AppKit
import BrowserBridge
import BrowserCore
import WebKit
@testable import NoodleBrowser
import XCTest

final class BrowserIdleSurfaceTests: XCTestCase {
    @MainActor func testEndingAttentionDetachesThePageWithoutClosingTheTab() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        XCTAssertEqual(runtime.agentAttention, .seconds(300))
        let tab = try runtime.makeTab(browserID: library.create(name: "Work").id), size = tab.web.frame.size
        tab.attend(for: .seconds(300))
        XCTAssertTrue(tab.web.window === tab.surface)
        tab.endAttention()
        XCTAssertNil(tab.web.window)
        XCTAssertNil(tab.surface.contentView)
        XCTAssertFalse(tab.surface.isVisible)
        XCTAssertEqual(tab.web.frame.size, size)
        XCTAssertTrue(runtime.tabs[tab.id] === tab)
        XCTAssertEqual(try library.profile(tab.browserID).tabs.map(\.id), [tab.id])
        tab.attend(for: .seconds(300))
        XCTAssertTrue(tab.web.window === tab.surface)
        XCTAssertTrue(tab.surface.isVisible)
        XCTAssertEqual(tab.surface.alphaValue, 0)
    }

    @MainActor func testWatchingReattachesADetachedPageAndLeavingDetachesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: library.create(name: "Work").id)
        tab.detachSurface(); tab.surface.contentView = nil
        tab.watched = true
        XCTAssertTrue(tab.web.window === tab.surface)
        XCTAssertTrue(tab.surface.isVisible)
        tab.watched = false
        XCTAssertNil(tab.web.window)
        XCTAssertFalse(tab.surface.isVisible)
    }

    @MainActor func testIdleChangesLeaveAPageInItsBrowserContainer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: library.create(name: "Work").id)
        tab.attend(for: .seconds(300)); tab.detachSurface()
        let container = BrowserWebContainer(web: tab.web)
        tab.endAttention(); tab.restoreSurface()
        XCTAssertTrue(tab.web.superview === container, "the background surface stole a page waiting to mount in the browser")
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = container
        tab.attend(for: .seconds(300)); tab.endAttention()
        XCTAssertTrue(tab.web.window === window)
    }

    @MainActor func testAPendingDialogKeepsItsPageAttached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: library.create(name: "Work").id)
        tab.attend(for: .seconds(300))
        tab.dialog = .init(kind: "alert", message: "Pending", origin: "fixture")
        tab.endAttention()
        XCTAssertTrue(tab.web.window === tab.surface)
        tab.dialog = nil
        XCTAssertNil(tab.web.window)
    }

    @MainActor func testAnOperationKeepsItsPageAttachedUntilItFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: library.create(name: "Work").id)
        let signal = SurfaceOperationStarted()
        tab.web.configuration.userContentController.add(signal, name: "surfaceOperationStarted")
        defer { tab.web.configuration.userContentController.removeScriptMessageHandler(forName: "surfaceOperationStarted") }
        tab.attend(for: .seconds(300))
        var operation: Task<Bool, Error>?
        await withCheckedContinuation { continuation in
            signal.ready = { continuation.resume() }
            operation = Task { @MainActor in
                try await tab.evaluate("return await new Promise(resolve=>{window.finishSurfaceOperation=resolve;window.webkit.messageHandlers.surfaceOperationStarted.postMessage(true)});") as? Bool ?? false
            }
        }
        tab.endAttention()
        XCTAssertTrue(tab.web.window === tab.surface)
        _ = try await tab.web.callAsyncJavaScript("finishSurfaceOperation(true); return true;", contentWorld: .page)
        let completed = try await XCTUnwrap(operation).value
        XCTAssertTrue(completed)
        XCTAssertNil(tab.web.window)
    }

    @MainActor func testAgentCommandsResumeTheSamePageAndNativeClicks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work").id
        let opened = try await runtime.perform(.init(.open, browserID: browser))
        let tab = try runtime.tab(browserID: browser, tabID: XCTUnwrap(opened.tabID))
        var eval = BrowserRequest(.eval, browserID: browser, tabID: tab.id)
        eval.text = "window.marker={value:'kept'};document.body.innerHTML='<input id=edit><button id=counter>Click</button>';document.querySelector('#edit').value='unsaved';window.clicked=new Promise(resolve=>document.querySelector('#counter').onclick=()=>resolve(true));return true;"
        _ = try await runtime.perform(eval)
        tab.endAttention()
        XCTAssertNil(tab.web.window)
        eval.text = "await new Promise(requestAnimationFrame);return marker.value==='kept' && document.querySelector('#edit').value==='unsaved' && document.visibilityState==='visible';"
        let resumed = try await runtime.perform(eval)
        XCTAssertEqual(resumed.text, "true")
        XCTAssertTrue(tab.web.window === tab.surface)
        var click = BrowserRequest(.click, browserID: browser, tabID: tab.id); click.target = "#counter"
        _ = try await runtime.perform(click)
        eval.text = "return await clicked;"
        let clicked = try await runtime.perform(eval)
        XCTAssertEqual(clicked.text, "true")
    }
}

@MainActor private final class SurfaceOperationStarted: NSObject, WKScriptMessageHandler {
    var ready: (() -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let callback = ready; ready = nil; callback?()
    }
}
