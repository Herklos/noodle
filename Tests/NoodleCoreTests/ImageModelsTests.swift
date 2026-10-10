import Foundation
import XCTest
@testable import NoodleCore

final class ImageModelsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testSettingsGrantEachAssignedBotAndNothingWhenUnreadable() throws {
        let agent = UUID()
        var settings = ImageGenerationSettings()
        settings.agents = [agent.uuidString, "not-a-bot"]
        settings.defaultModel = "sdxl-turbo"
        try settings.save(root: root)
        let loaded = try ImageGenerationSettings.load(root: root)
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.toolAssignments(readable: true), [agent: ["default"]])
        XCTAssertEqual(loaded.toolAssignments(readable: false), [:])
    }

    func testOnlyCatalogueModelsWithReadableInformationAreListed() throws {
        let store = ImageModelStore(repository: root)
        let model = ImageModel(id: "sdxl-turbo", name: "SDXL Turbo", summary: "", repository: "stabilityai/sdxl-turbo",
                               steps: 2, guidance: 0, size: 512, byteCount: 1)
        let folder = store.directory.appendingPathComponent(model.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(model).write(to: folder.appendingPathComponent("model.json"))
        // A half-finished download and an unknown folder are never offered.
        try FileManager.default.createDirectory(at: store.directory.appendingPathComponent(".download-x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.directory.appendingPathComponent("juggernaut-xl"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.directory.appendingPathComponent("other"), withIntermediateDirectories: true)
        XCTAssertEqual(store.models(), [model])
        XCTAssertEqual(try store.weights(id: model.id), folder.appendingPathComponent("weights", isDirectory: true))
        XCTAssertThrowsError(try store.weights(id: "../other"))
        store.removeAbandonedStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(".download-x").path))
        try store.remove(id: model.id)
        XCTAssertEqual(store.models(), [])
    }

    func testDownloadStoresFp16WeightsWhereTheLoaderLooksAndStopsOnABadFile() async throws {
        let store = ImageModelStore(repository: root)
        let downloadable = try XCTUnwrap(ImageDownloadableModel.available.first)
        let fetched = Fetched()
        // Every file arrives wrong, so the first check fails and nothing is published.
        do {
            _ = try await store.download(downloadable, progress: { _ in }) { url, destination, _, _ in
                await fetched.append(url.lastPathComponent)
                try Data("wrong".utf8).write(to: destination)
            }
            XCTFail("A file with the wrong size was accepted")
        } catch {}
        let names = await fetched.names
        XCTAssertEqual(names, ["config.json"])
        XCTAssertEqual(store.models(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
        XCTAssertTrue(downloadable.files.allSatisfy { !$0.name.contains(".fp16.") })
        XCTAssertTrue(downloadable.files.filter { $0.name.hasSuffix(".safetensors") }.allSatisfy { $0.source.contains(".fp16.") })
    }
}

private actor Fetched {
    var names: [String] = []
    func append(_ name: String) { names.append(name) }
}
