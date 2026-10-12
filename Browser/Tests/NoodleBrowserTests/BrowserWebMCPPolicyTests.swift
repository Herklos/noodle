import BrowserCore
import Foundation
@testable import NoodleBrowser
import XCTest

final class BrowserWebMCPPolicyTests: XCTestCase {
    @MainActor func testResponseOptOutAndOriginIsolation() throws {
        func permitted(_ headers: [String: String]) -> Bool {
            BrowserWebMCP.permits(HTTPURLResponse(url: URL(string: "https://example.com/page")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        XCTAssertTrue(permitted([:]))
        XCTAssertTrue(permitted(["Permissions-Policy": "camera=(), tools=(self)"]))
        XCTAssertTrue(permitted(["Permissions-Policy": "tools=*"]))
        XCTAssertTrue(permitted(["Permissions-Policy": "tools=(\"https://example.com\")"]))
        XCTAssertFalse(permitted(["Permissions-Policy": "tools=()", "Origin-Agent-Cluster": "?1"]))
        XCTAssertFalse(permitted(["Permissions-Policy": "tools=(\"https://elsewhere.example\")"]))
        XCTAssertFalse(permitted(["Permissions-Policy": "tools=garbage"]))
        XCTAssertFalse(permitted(["Permissions-Policy": "tools=*, tools=()"] ))
        XCTAssertFalse(permitted(["Origin-Agent-Cluster": "?0"]))
    }

    /// Tools are only what a page registers. Annotated forms are not tools, and nothing watches
    /// the page for them, so busy pages pay nothing for WebMCP.
    @MainActor func testOnlyRegisteredToolsAreListed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: try library.create(name: "Work").id)
        _ = tab.web.loadHTMLString("""
            <form toolname="book_table" tooldescription="Book a table"><input name="guest"></form>
            <script>document.modelContext.registerTool({name: 'echo', description: 'Echo', execute: args => args})</script>
            """, baseURL: URL(string: "https://example.com/"))
        try await eventually { (try? await tab.evaluate("return document.readyState")) as? String == "complete" }
        let listed = try await tab.evaluate("return (await __noodleWebMCP.list()).tools.map(t => t.name)") as? [String]
        XCTAssertEqual(listed, ["echo"])
        let watched = try await tab.evaluate("""
            let changes = 0; document.modelContext.ontoolchange = () => changes++;
            document.body.insertAdjacentHTML('beforeend', '<form toolname="order" tooldescription="Order"><input name="dish"></form>');
            await new Promise(resolve => setTimeout(resolve, 50));
            return changes;
            """) as? Int
        XCTAssertEqual(watched, 0, "WebMCP watches the page for changes")
    }
    @MainActor private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 where !(await condition()) { try await Task.sleep(for: .milliseconds(50)) }
    }
}
