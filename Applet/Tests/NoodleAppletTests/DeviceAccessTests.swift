import AppletBridge
import AppletCore
import XCTest

@testable import NoodleApplet

/// What Noodle Hub asks of Applet so a person's device runs a bot's noodlet itself: its files, and
/// its data and secrets, which stay on this Mac.
@MainActor final class DeviceAccessTests: XCTestCase {
    private var root: URL!
    private var runtime: AppletRuntime!
    private var secrets: AppletSecrets!
    private let hub = AppletBuildIdentity.current.hubID

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DeviceAccess." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!); defaults.removePersistentDomain(forName: suite) }
        secrets = AppletSecrets(storage: MemorySecrets())
        runtime = AppletRuntime(library: botLibrary(root: root, defaults: defaults, secrets: secrets), defaults: defaults)
    }

    private func noodlet(_ files: [String: Data]) async throws -> (UUID, NoodletPackage) {
        var validate = AppletRequest(.validate)
        validate.path = try botNoodlet(files, named: "Pocket", owner: "bot", root: root, hub: true)
        let response = try await runtime.handle(validate, identity: hub).checked()
        return (try XCTUnwrap(response.noodletID), try NoodletPackage(url: URL(fileURLWithPath: try XCTUnwrap(response.path))))
    }

    private func store(_ id: UUID, _ call: NoodletStoreCall) async throws -> NoodletValue? {
        var request = AppletRequest(.store)
        request.noodletID = id
        request.store = call
        return try await runtime.handle(request, identity: hub).checked().stored
    }

    func testTheHubGetsANoodletsFilesAsOneArchive() async throws {
        var files = try htmlNoodlet("Pocket")
        files["art/logo.svg"] = Data("<svg/>".utf8)
        let (id, package) = try await noodlet(files)
        var request = AppletRequest(.archive)
        request.noodletID = id
        let response = try await runtime.handle(request, identity: hub).checked()
        XCTAssertEqual(response.revision, package.revision)
        XCTAssertEqual(response.manifest?.title, "Pocket")
        XCTAssertEqual(response.byteCount, files.values.reduce(0) { $0 + $1.count }, "not the size of its files")
        let (archive, total) = try await read(try XCTUnwrap(response.artifactID))
        XCTAssertEqual(archive.count, total)
        let file = root.appendingPathComponent("received.noodletarchive")
        try archive.write(to: file)
        let out = root.appendingPathComponent("Out.noodlet")
        try NoodletArchive.extract(file, to: out)
        for (name, data) in files { XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(name)), data, name) }
    }

    /// The archive, read piece by piece as the Hub does, asking again while it is still being
    /// written; and its size, which only the finished archive tells.
    private func read(_ artifact: UUID) async throws -> (Data, Int?) {
        var archive = Data()
        var total: Int?
        for _ in 0..<10_000 {
            var piece = AppletRequest(.artifact)
            piece.artifactID = artifact
            piece.offset = archive.count
            let read = try await runtime.handle(piece, identity: hub).checked()
            let data = try XCTUnwrap(read.data)
            if data.isEmpty, read.done != true {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            archive.append(data)
            total = read.byteCount
            if read.done == true { return (archive, total) }
        }
        throw AppletError("The archive was never written.")
    }

    /// The Hub hears the noodlet's revision and manifest before its archive is written, so a
    /// device knows at once whether it has that revision; the archive's pieces follow once written.
    func testTheHubHearsOfANoodletBeforeItsArchiveIsWritten() async throws {
        let (id, package) = try await noodlet(try htmlNoodlet("Pocket"))
        let gate = DispatchSemaphore(value: 0)
        let pack = runtime.pack
        runtime.pack = { package, url in
            gate.wait()
            try pack(package, url)
        }
        var request = AppletRequest(.archive)
        request.noodletID = id
        let response = try await runtime.handle(request, identity: hub).checked()
        XCTAssertEqual(response.revision, package.revision)
        var piece = AppletRequest(.artifact)
        piece.artifactID = response.artifactID
        piece.offset = 0
        let early = try await runtime.handle(piece, identity: hub).checked()
        XCTAssertEqual(early.data, Data())
        XCTAssertNotEqual(early.done, true)
        XCTAssertNil(early.byteCount)
        gate.signal()
        let (archive, total) = try await read(try XCTUnwrap(response.artifactID))
        XCTAssertEqual(archive.count, total)
    }

    /// A device's page keeps the same data and secrets as the noodlet has on this Mac.
    func testTheHubReachesTheNoodletsOwnDataAndSecrets() async throws {
        let (id, package) = try await noodlet(try htmlNoodlet("Pocket"))
        let hello = Data("hello".utf8).base64EncodedString()
        let wrote = try await store(id, NoodletStoreCall(operation: "write", path: "notes/a.txt", data: hello))
        XCTAssertEqual(wrote, .bool(true))
        let data = root.appendingPathComponent("Data/\(package.key)/User/notes/a.txt")
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "hello")
        let read = try await store(id, NoodletStoreCall(operation: "read", path: "notes/a.txt"))
        XCTAssertEqual(read, .text(hello))
        // Bytes come back as they went, not as text.
        let bytes = Data([0, 255, 10, 13, 128]).base64EncodedString()
        _ = try await store(id, NoodletStoreCall(operation: "write", path: "blob.bin", data: bytes))
        let readBytes = try await store(id, NoodletStoreCall(operation: "read", path: "blob.bin"))
        XCTAssertEqual(readBytes, .text(bytes))
        guard case .entries(let listed)? = try await store(id, NoodletStoreCall(operation: "list", path: "notes/")) else {
            return XCTFail("list did not answer entries")
        }
        XCTAssertEqual(listed.map(\.path), ["notes/a.txt"])
        XCTAssertEqual(listed.map(\.size), [5])
        guard case .entries(let all)? = try await store(id, NoodletStoreCall(operation: "list")) else {
            return XCTFail("list did not answer entries")
        }
        XCTAssertEqual(all.map(\.path), ["blob.bin", "notes/a.txt"])
        let set = try await store(id, NoodletStoreCall(operation: "secret", action: "set", name: "token", value: "t"))
        XCTAssertEqual(set, .bool(true))
        XCTAssertEqual(secrets.names(), ["\(package.key).user": ["token"]])
        var escape = AppletRequest(.store)
        escape.noodletID = id
        escape.store = NoodletStoreCall(operation: "write", path: "../../x.txt", data: "eA==")
        let escaped = await runtime.handle(escape, identity: hub)
        XCTAssertNotNil(escaped.error)
    }

    func testRequestsNameTheNoodletAndTheirCall() throws {
        XCTAssertThrowsError(try AppletRequest(.archive).validate())
        var store = AppletRequest(.store)
        store.noodletID = UUID()
        XCTAssertThrowsError(try store.validate())
        var stray = AppletRequest(.info)
        stray.noodletID = UUID()
        stray.store = NoodletStoreCall(operation: "read", path: "a.txt")
        XCTAssertThrowsError(try stray.validate())
    }
}
