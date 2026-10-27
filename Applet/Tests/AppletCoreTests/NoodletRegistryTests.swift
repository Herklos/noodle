import AppletBridge
import AppletCore
import XCTest

final class NoodletRegistryTests: XCTestCase {
    func testIdentitySurvivesUpdatesReloadAndMovesButCopiesAreIndependent() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("A.noodlet")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("registry.json")
        let registry = try NoodletRegistry(file: file)
        let id = try registry.id(for: source)
        try Data("updated".utf8).write(to: source.appendingPathComponent("index.html"))
        XCTAssertEqual(try registry.id(for: source), id)
        let reloaded = try NoodletRegistry(file: file)
        XCTAssertEqual(reloaded.resolve(id)?.path, source.resolvingSymlinksInPath().path)
        let copy = root.appendingPathComponent("Copy.noodlet")
        try manager.copyItem(at: source, to: copy)
        XCTAssertNotEqual(try reloaded.id(for: copy), id)
        let moved = root.appendingPathComponent("Moved.noodlet")
        try manager.moveItem(at: source, to: moved)
        XCTAssertEqual(reloaded.resolve(id)?.path, moved.resolvingSymlinksInPath().path)
        XCTAssertEqual(try reloaded.id(for: moved), id)
        try manager.removeItem(at: moved)
        XCTAssertNil(reloaded.resolve(id))
        XCTAssertNil(reloaded.resolve(UUID()))
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try NoodletRegistry(file: file))
    }

    /// The library lists what the registry knows: moved packages follow their bookmark, packages
    /// gone are forgotten, and a package can be forgotten on purpose.
    func testPackagesFollowMovesAndForgetWhatIsGone() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        func make(_ name: String) throws -> URL {
            let url = root.appendingPathComponent("\(name).noodlet")
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        let (kept, moving, gone, forgotten) = (try make("Kept"), try make("Moving"), try make("Gone"), try make("Forgotten"))
        let file = root.appendingPathComponent("registry.json")
        let registry = try NoodletRegistry(file: file)
        let id = try registry.id(for: moving)
        for url in [kept, gone, forgotten] { _ = try registry.id(for: url) }
        let moved = root.appendingPathComponent("Moved.noodlet").resolvingSymlinksInPath().standardizedFileURL
        try manager.moveItem(at: moving, to: moved)
        try manager.removeItem(at: gone)
        try registry.forget(forgotten)

        XCTAssertEqual(Set(registry.packages().map(\.path)), [kept.path, moved.path])
        let reloaded = try NoodletRegistry(file: file)
        XCTAssertEqual(Set(reloaded.packages().map(\.path)), [kept.path, moved.path])
        XCTAssertEqual(try reloaded.id(for: moved), id, "Links already shared still open the moved package")
    }

    func testLinksAreStrictAndCannotCombineIDWithAnotherTarget() throws {
        let id = UUID(), url = NoodletLink.url(for: UUID())
        XCTAssertEqual(NoodletLink.id(in: NoodletLink.url(for: id)), id)
        for string in [url.absoluteString + "/", url.absoluteString + "/file.noodlet",
                       url.absoluteString + "?path=/tmp/a", url.absoluteString + "#fragment",
                       "noodlet://user@\(id)", "noodlet://\(id):80", "noodlet:///tmp/a.noodlet",
                       "noodlet://open/\(id)", "https://\(id)", "noodlet://hello"] {
            XCTAssertNil(NoodletLink.id(in: URL(string: string)!), string)
        }
        for target in 0..<3 {
            var request = AppletRequest(.open)
            request.noodletID = id
            XCTAssertNoThrow(try request.validate())
            if target == 0 { request.path = "/tmp/a.noodlet" }
            if target == 1 { request.sessionID = UUID() }
            if target == 2 { request.files = [:] }
            XCTAssertThrowsError(try request.validate())
        }
    }
}
