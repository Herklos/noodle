import BrowserCore
import WebKit
@testable import NoodleBrowser
import XCTest

final class BrowserMemoryPressureTests: XCTestCase {
    /// A warning trims only disposable memory caches, once per live profile for a pressure episode.
    @MainActor func testPressureTrimsOnlyMemoryCachesOfLiveProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let a = try library.create(name: "A"), b = try library.create(name: "B")
        _ = try library.create(name: "Not loaded")
        let first = try runtime.makeTab(browserID: a.id)
        _ = try runtime.makeTab(browserID: a.id)
        let second = try runtime.makeTab(browserID: b.id)
        var removals: [(UUID?, Set<String>)] = []
        runtime.removeWebsiteData = { store, types, completion in
            removals.append((store.identifier, types)); completion()
        }
        runtime.handleMemoryPressure(.normal)
        XCTAssertTrue(removals.isEmpty)
        runtime.handleMemoryPressure(.warning)
        XCTAssertEqual(Set(removals.compactMap(\.0)), [a.id, b.id])
        XCTAssertEqual(removals.count, 2)
        XCTAssertTrue(removals.allSatisfy { $0.1 == [WKWebsiteDataTypeMemoryCache] })
        runtime.handleMemoryPressure(.warning)
        runtime.handleMemoryPressure(.critical)
        XCTAssertEqual(removals.count, 2, "sustained pressure repeatedly discarded freshly fetched resources")
        XCTAssertTrue(runtime.tabs[first.id] === first)
        XCTAssertTrue(runtime.tabs[second.id] === second)
        XCTAssertEqual(runtime.tabs.count, 3)
        runtime.handleMemoryPressure(.normal)
        runtime.handleMemoryPressure(.critical)
        XCTAssertEqual(removals.count, 4, "a new pressure episode did not trim the caches")
    }

    @MainActor func testAnUnfinishedTrimIsNotStartedAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        _ = try runtime.makeTab(browserID: try library.create(name: "A").id)
        var completions: [@MainActor @Sendable () -> Void] = []
        runtime.removeWebsiteData = { _, _, completion in completions.append(completion) }
        runtime.handleMemoryPressure(.warning)
        XCTAssertEqual(completions.count, 1)
        runtime.handleMemoryPressure(.normal)
        runtime.handleMemoryPressure(.critical)
        XCTAssertEqual(completions.count, 1)
        completions.first?()
        runtime.handleMemoryPressure(.critical)
        XCTAssertEqual(completions.count, 2)
        completions.last?()
    }

    /// A profile opened after a warning still has its caches trimmed, without reopening unloaded profiles.
    @MainActor func testAProfileOpenedDuringPressureIsTrimmedOnTheNextNotice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let a = try library.create(name: "A"), b = try library.create(name: "B")
        _ = try runtime.makeTab(browserID: a.id)
        var removals: [UUID?] = []
        runtime.removeWebsiteData = { store, _, completion in removals.append(store.identifier); completion() }
        runtime.handleMemoryPressure(.warning)
        XCTAssertEqual(removals, [a.id])
        _ = try runtime.makeTab(browserID: b.id)
        runtime.handleMemoryPressure(.warning)
        XCTAssertEqual(removals, [a.id, b.id])
    }

    /// Exercise the real WebKit removal, with no server or navigation: live DOM/JS state and cookies survive it.
    @MainActor func testRealCacheRemovalPreservesTheCurrentPageAndCookies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: try library.create(name: "A").id)
        let store = tab.web.configuration.websiteDataStore
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "memory-fixture.invalid", .path: "/", .name: "session", .value: "kept"]))
        await store.httpCookieStore.setCookie(cookie)
        _ = try await tab.evaluate("window.payload = new Uint8Array(1 << 20); payload.fill(7); document.body.innerHTML = '<input id=edit>'; document.querySelector('#edit').value = 'unsaved'; return true;")
        let remove = runtime.removeWebsiteData
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            runtime.removeWebsiteData = { store, types, completion in
                remove(store, types) { completion(); continuation.resume() }
            }
            runtime.handleMemoryPressure(.warning)
        }
        let kept = try await tab.evaluate("return payload.byteLength === (1 << 20) && payload[0] === 7 && document.querySelector('#edit').value === 'unsaved';")
        XCTAssertEqual(kept as? Bool, true, "cache cleanup replaced the current document or lost its edits")
        XCTAssertTrue(runtime.tabs[tab.id] === tab)
        let cookies = await store.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "session" && $0.value == "kept" })
    }
}
