import BrowserBridge
import BrowserCore
import Network
@testable import NoodleBrowser
import XCTest

final class BrowserRuntimeTests: XCTestCase {
    @MainActor func testBrowsersTheHubMakesOrUsesAreListedAsHub() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), identity = BrowserBuildIdentity.current
        let runtime = BrowserRuntime(library: library)
        var create = BrowserRequest(.create); create.profile = BrowserDraft(name: "Hub made")
        let made = try await runtime.perform(create, caller: identity.hubID).browser!
        XCTAssertEqual(try library.profile(made.id).hub, true)
        let own = try await runtime.perform(create, caller: identity.noodleID).browser!
        XCTAssertNil(try library.profile(own.id).hub)
        // Made by the Hub before it said so: the Hub only ever uses its own.
        let earlier = try library.create(name: "Earlier")
        _ = try await runtime.perform(.init(.bookmarks, browserID: earlier.id), caller: identity.noodleID)
        XCTAssertNil(try library.profile(earlier.id).hub)
        _ = try await runtime.perform(.init(.bookmarks, browserID: earlier.id), caller: identity.hubID)
        XCTAssertEqual(try library.profile(earlier.id).hub, true)
    }
    @MainActor func testOnlyTheHubSaysWhomABrowserIsKeptFor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), identity = BrowserBuildIdentity.current
        let runtime = BrowserRuntime(library: library), made = try library.create(name: "Work")
        var set = BrowserRequest(.setOwner, browserID: made.id)
        set.owner = BrowserOwner(id: UUID(), name: "Eve")
        do { _ = try await runtime.perform(set, caller: identity.noodleID); XCTFail("Noodle said whom a browser is for") } catch {}
        XCTAssertNil(try library.profile(made.id).hubOwner)
        let ada = BrowserOwner(id: UUID(), name: "Ada")
        set.owner = ada
        _ = try await runtime.perform(set, caller: identity.hubID)
        XCTAssertEqual(try library.profile(made.id).hubOwner, ada)
        let listed = try await runtime.perform(.init(.list), caller: identity.hubID).browsers
        XCTAssertEqual(listed?.first?.owner, ada)
        set.owner = nil
        _ = try await runtime.perform(set, caller: identity.hubID)
        XCTAssertNil(try library.profile(made.id).hubOwner)
    }
    @MainActor func testRecordCommandsRespectPauseAndProfileOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), a = try library.create(name: "A"), b = try library.create(name: "B")
        let runtime = BrowserRuntime(library: library)
        var add = BrowserRequest(.bookmarkAdd, browserID: a.id); add.url = "https://example.com"; add.title = "Example"
        let response = try await runtime.perform(add)
        let bookmark = try XCTUnwrap(response.bookmark)
        var update = BrowserRequest(.bookmarkUpdate, browserID: b.id); update.bookmarkID = bookmark.id; update.title = "Wrong profile"
        do { _ = try await runtime.perform(update); XCTFail("Cross-profile bookmark changed") } catch {}
        update.browserID = a.id; update.title = "Saved"
        let edited = try await runtime.perform(update); XCTAssertEqual(edited.bookmark?.title, "Saved")
        _ = try library.recordVisit(a.id, url: "https://example.com", title: "Visited")
        try runtime.setPaused(true, browserID: a.id)
        for request in [add, update] {
            do { _ = try await runtime.perform(request); XCTFail("Paused bookmark mutation") } catch {}
        }
        var remove = BrowserRequest(.bookmarkRemove, browserID: a.id); remove.bookmarkID = bookmark.id
        do { _ = try await runtime.perform(remove); XCTFail("Paused bookmark removal") } catch {}
        let saved = try await runtime.perform(.init(.bookmarks, browserID: a.id))
        XCTAssertEqual(saved.totalCount, 1); XCTAssertEqual(saved.limit, 50); XCTAssertEqual(saved.offset, 0)
        let visits = try await runtime.perform(.init(.history, browserID: a.id))
        XCTAssertEqual(visits.history?.first?.title, "Visited")
        try runtime.setPaused(false, browserID: a.id)
        _ = try await runtime.perform(remove)
        let empty = try await runtime.perform(.init(.bookmarks, browserID: a.id)); XCTAssertEqual(empty.totalCount, 0)
    }
    @MainActor func testPauseAndTabOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root)
        var a = try library.create(name: "A"), b = try library.create(name: "B")
        a.tabs = [.init()]; try library.update(a)
        let runtime = BrowserRuntime(library: library)
        do { _ = try runtime.tab(browserID: b.id, tabID: a.tabs[0].id); XCTFail("Cross-profile access") } catch {}
        try runtime.setPaused(true, browserID: a.id)
        do { _ = try await runtime.perform(.init(.open, browserID: a.id)); XCTFail("Paused browser opened") } catch {}
        let response = try await runtime.perform(.init(.status, browserID: a.id))
        XCTAssertEqual(response.browser?.paused, true)
        XCTAssertEqual(response.tabs?.first?.id, a.tabs[0].id)
        var download = BrowserRequest(.download, browserID: b.id); download.fileID = UUID()
        do { _ = try await runtime.perform(download); XCTFail("Unknown download") } catch {}
    }
    @MainActor func testTabsNobodyUsedForTheExpiryAreClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), now = Date(), day: TimeInterval = 86_400
        var a = try library.create(name: "A")
        let old = BrowserTabInfo(lastUsed: now - 8 * day), recent = BrowserTabInfo(lastUsed: now - day), unknown = BrowserTabInfo()
        a.tabs = [old, recent, unknown]; a.selectedTabID = old.id; try library.update(a)
        let runtime = BrowserRuntime(library: library)
        runtime.expireTabs(unusedFor: 7 * day, now: now)
        let tabs = try library.profile(a.id).tabs
        XCTAssertEqual(tabs.map(\.id), [recent.id, unknown.id])
        XCTAssertEqual(try library.profile(a.id).selectedTabID, recent.id)
        // A tab with no record of use has its time start now rather than being closed.
        XCTAssertEqual(tabs.last?.lastUsed, now)
        runtime.expireTabs(unusedFor: 7 * day, now: now + 6.5 * day)
        XCTAssertEqual(try library.profile(a.id).tabs.map(\.id), [unknown.id])
    }
    @MainActor func testPeopleBotsAndLiveViewersUsingATabKeepItOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), long = Date() - 30 * 86_400
        var a = try library.create(name: "A")
        let first = BrowserTabInfo(lastUsed: long), second = BrowserTabInfo(lastUsed: long), third = BrowserTabInfo(lastUsed: long)
        a.tabs = [first, second, third]; a.selectedTabID = first.id; try library.update(a)
        let runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        func used(_ id: UUID) throws -> Date { try XCTUnwrap(library.profile(a.id).tabs.first { $0.id == id }?.lastUsed) }
        // A bot.
        var reload = BrowserRequest(.reload, browserID: a.id); reload.tabID = first.id
        _ = try await runtime.perform(reload)
        XCTAssertGreaterThan(try used(first.id), long)
        // A person choosing a tab.
        try runtime.selectTab(browserID: a.id, tabID: second.id)
        XCTAssertGreaterThan(try used(second.id), long)
        // Someone watching live, acting on the selected tab.
        try runtime.selectTab(browserID: a.id, tabID: third.id)
        var profile = try library.profile(a.id)
        profile.tabs[2].lastUsed = long; try library.update(profile)
        runtime.tabs[third.id]?.info.lastUsed = long
        try BrowserLiveView(browserID: a.id, runtime: runtime).apply(.scroll(x: 10, y: 400, dx: 0, dy: 10))
        XCTAssertGreaterThan(try used(third.id), long)
        // A new tab starts as used.
        let opened = try await runtime.perform(.init(.open, browserID: a.id))
        XCTAssertNotNil(try used(XCTUnwrap(opened.tabID)))
    }
    /// Only the most recently used pages keep running. The rest stop but stay in the tab strip,
    /// with their address and icon, and load again when used; the tab on screen and one waiting on
    /// a dialog keep running.
    @MainActor func testOnlyRecentlyUsedPagesKeepRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root)
        var a = try library.create(name: "A")
        let infos = (0..<12).map { BrowserTabInfo(title: "Page \($0)", url: "https://example.com/\($0)") }
        a.tabs = infos; a.selectedTabID = infos[0].id; try library.update(a)
        let runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        _ = try runtime.tab(browserID: a.id, tabID: infos[0].id)
        try runtime.tab(browserID: a.id, tabID: infos[1].id).dialog = BrowserDialog(kind: "alert", message: "Hi", origin: "example.com")
        for info in infos[2...] { _ = try runtime.tab(browserID: a.id, tabID: info.id) }
        XCTAssertEqual(runtime.tabs.count, BrowserRuntime.runningPageLimit)
        XCTAssertNotNil(runtime.tabs[infos[0].id], "the tab on screen stopped")
        XCTAssertNotNil(runtime.tabs[infos[1].id], "a tab waiting on a dialog stopped")
        XCTAssertNil(runtime.tabs[infos[2].id], "the least recently used page kept running")
        XCTAssertEqual(try library.profile(a.id).tabs.map(\.id), infos.map(\.id), "stopping a page closed its tab")
        let reloaded = try runtime.tab(browserID: a.id, tabID: infos[2].id)
        XCTAssertEqual(reloaded.web.url?.absoluteString, "https://example.com/2")
        XCTAssertEqual(runtime.tabs.count, BrowserRuntime.runningPageLimit)
    }
    /// A page that stopped comes back with its history, so going back still works.
    @MainActor func testAStoppedPageComesBackWithItsHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root)
        var a = try library.create(name: "A")
        let infos = (0...BrowserRuntime.runningPageLimit).map { _ in BrowserTabInfo() }
        a.tabs = infos; a.selectedTabID = infos[0].id; try library.update(a)
        let runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let server = try await LoopbackPages.start()
        defer { server.cancel() }
        func page(_ text: String) throws -> URL { try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port!.rawValue)/\(text)")) }
        func settle(_ tab: BrowserTab, at url: URL) async throws {
            for _ in 0..<100 where tab.web.url != url || tab.web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(tab.web.url, url)
        }
        let first = try page("first"), second = try page("second")
        _ = try runtime.tab(browserID: a.id, tabID: infos[0].id)
        let tab = try runtime.tab(browserID: a.id, tabID: infos[1].id)
        tab.navigate(first); try await settle(tab, at: first)
        tab.navigate(second); try await settle(tab, at: second)
        for info in infos[2...] { _ = try runtime.tab(browserID: a.id, tabID: info.id) }
        XCTAssertNil(runtime.tabs[infos[1].id], "the page did not stop")
        let restored = try runtime.tab(browserID: a.id, tabID: infos[1].id)
        try await settle(restored, at: second)
        XCTAssertTrue(restored.web.canGoBack, "the page came back without its history")
        XCTAssertEqual(restored.web.backForwardList.backItem?.url, first)
    }
    /// Pages change their title and address many times a second; the library shows each change
    /// at once but writes them to disk together, and none is lost when the browser stops.
    @MainActor func testTabChangesShowAtOnceAndReachDiskTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        let tab = try runtime.makeTab(browserID: try library.create(name: "Work").id)
        let archive = root.appendingPathComponent("browsers.json"), saved = try Data(contentsOf: archive)
        for count in 1...20 { tab.info.title = "(\(count)) Feed"; runtime.saveTab(tab) }
        XCTAssertEqual(try library.profile(tab.browserID).tabs.first?.title, "(20) Feed")
        XCTAssertEqual(try Data(contentsOf: archive), saved, "every change rewrote the library")
        runtime.shutdown()
        XCTAssertEqual(try BrowserLibrary(root: root).profile(tab.browserID).tabs.first?.title, "(20) Feed")
    }

    /// A long home folder name must not push the connection past the platform's socket path limit.
    func testLongConnectionPathRegistersAndAnswers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(String(repeating: "x", count: 110))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("b.sock")
        let server = try BrowserConnectionServer(socket: url, team: "1234567890") { _, _ in .init() }
        XCTAssertThrowsError(try BrowserConnectionServer(socket: url, team: "1234567890") { _, _ in .init() }) {
            XCTAssertEqual($0.localizedDescription, "A browser provider is already running.")
        }
        withExtendedLifetime(server) {}
    }
}

/// Answers every request on 127.0.0.1 with a small page, so tests load real addresses without the network.
enum LoopbackPages {
    static func start() async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let body = "<p>page</p>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { if case .ready = $0 { ready.resume(); listener.stateUpdateHandler = nil } }
            listener.start(queue: .global())
        }
        return listener
    }
}
