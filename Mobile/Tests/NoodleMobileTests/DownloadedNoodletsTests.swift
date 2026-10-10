import Foundation
import HubLink
@testable import NoodleMobile
import Testing

/// Settings lists the noodlets kept on this phone, from every Hub, so the person can delete them to free up space.
@MainActor @Suite struct DownloadedNoodletsTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func keep(_ title: String, bytes: Int, hub: String, in root: URL) throws -> URL {
        let noodlet = root.appendingPathComponent(hub).appendingPathComponent(UUID().uuidString.lowercased())
        let package = noodlet.appendingPathComponent("abc1")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(#"{"version":1,"title":"\#(title)","runtime":"web","entry":"index.html"}"#.utf8)
            .write(to: package.appendingPathComponent("noodlet.json"))
        try Data(count: bytes).write(to: package.appendingPathComponent("game.wasm"))
        return noodlet
    }

    @Test func everyHubsNoodletsAreListedLargestFirstWithTheirTitles() throws {
        let root = try folder()
        let notes = try keep("Notes", bytes: 10_000, hub: "studio", in: root)
        let racer = try keep("Racer", bytes: 2_000_000, hub: "home", in: root)
        let unfinished = root.appendingPathComponent("home").appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: unfinished.appendingPathComponent(".\(UUID().uuidString)"))

        let kept = DownloadedNoodlet.all(in: root)
        #expect(kept.map(\.folder.standardizedFileURL) == [racer, unfinished, notes].map(\.standardizedFileURL))
        #expect(kept.map(\.title) == ["Racer", nil, "Notes"])
        #expect(kept[0].byteCount >= 2_000_000)
        #expect(DownloadedNoodlet.all(in: root.appendingPathComponent("missing")).isEmpty)
    }

    @Test func aDeletedNoodletLeavesThePhone() throws {
        let root = try folder()
        _ = try keep("Notes", bytes: 10, hub: "studio", in: root)
        let racer = try keep("Racer", bytes: 10, hub: "studio", in: root)
        try #require(DownloadedNoodlet.all(in: root).first { $0.title == "Racer" }).delete()
        #expect(!FileManager.default.fileExists(atPath: racer.path))
        #expect(DownloadedNoodlet.all(in: root).map(\.title) == ["Notes"])
    }

    /// What a Hub's noodlets download into is what Settings lists.
    @Test func eachHubKeepsItsNoodletsWhereSettingsLooks() {
        let studio = HubChats(pairing: HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                                  deviceName: "iPhone"))
        #expect(studio.noodletCache.deletingLastPathComponent().standardizedFileURL == DownloadedNoodlet.root.standardizedFileURL)
    }
}
