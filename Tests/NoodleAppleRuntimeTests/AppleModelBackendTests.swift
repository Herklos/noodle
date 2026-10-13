import XCTest
import FoundationModels
import NoodleCore
@testable import NoodleAppleRuntime

final class AppleModelBackendTests: XCTestCase {
    func testInspectionReportsBuildCapability() {
        let result = AppleModel.inspection(version: "test")
        XCTAssertEqual(result.version, "test")
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *) { XCTAssertEqual(result.localModelsSupported, true) }
        #else
        XCTAssertEqual(result.localModelsSupported, false)
        #endif
    }

    func testSystemModelIsOfferedOnlyAfterItIsAdded() throws {
        let models = FileManager.default.temporaryDirectory.appendingPathComponent("system-model-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: models) }
        let before = AppleModel.inspection(version: "test", modelsDirectory: models)
        XCTAssertFalse(before.models.contains { $0.id == "default" })
        XCTAssertNotNil(before.unavailableReason)
        try AppleLocalModelStore(directory: models).setSystemModelAdded(true)
        let added = AppleModel.inspection(version: "test", modelsDirectory: models)
        XCTAssertEqual(added.models.map(\.id), ["default"])
        XCTAssertEqual(added.unavailableReason, AppleModel.systemUnavailableReason)
        try AppleLocalModelStore(directory: models).setSystemModelAdded(false)
        XCTAssertEqual(AppleModel.inspection(version: "test", modelsDirectory: models).models.map(\.id), [])
    }

    func testUnknownModelCannotSilentlyFallBackToApple() async throws {
        guard #available(macOS 26, *) else { return }
        do {
            _ = try await AppleModelBackend.prepare(identifier: "missing-model", workspace: FileManager.default.temporaryDirectory)
            XCTFail("Invalid selection unexpectedly loaded a model")
        } catch { /* A missing/invalid selection must be reported. */ }
    }

    func testSavedModelIdentityAndLegacyTranscriptDecoding() throws {
        guard #available(macOS 26, *) else { return }
        let session = AppleConversationSession(transcript: Transcript(entries: []), modelIdentifier: "default")
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(AppleConversationSession.self, from: data).modelIdentifier, "default")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "modelIdentifier")
        XCTAssertNil(try JSONDecoder().decode(AppleConversationSession.self, from: JSONSerialization.data(withJSONObject: json)).modelIdentifier)
    }
}
