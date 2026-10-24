import ComputerBridge
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class ComputerProviderLaunchTests: XCTestCase {
    /// A running Computer that stopped answering is not opened again: every open showed
    /// another "not responding" alert and could not bring it back.
    func testARunningComputerThatDoesNotAnswerIsNotOpenedAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-launch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("workspace")); try repository.prepare()
        var launches = 0
        let controller = ComputerController(repository: repository, socket: root.appendingPathComponent("c.sock"), team: "1234567890",
                                            applicationLookup: { root }, launcher: { _ in launches += 1 },
                                            providerRunning: { true })
        do {
            _ = try await controller.call(.init(.templates))
            XCTFail("An unanswered request succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not answering"), error.localizedDescription)
        }
        XCTAssertEqual(launches, 0, "Opened a Computer that is already running")
    }

    func testAComputerThatIsNotRunningIsOpenedOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-launch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("workspace")); try repository.prepare()
        var launches = 0
        let controller = ComputerController(repository: repository, socket: root.appendingPathComponent("c.sock"), team: "1234567890",
                                            applicationLookup: { root }, launcher: { _ in launches += 1 },
                                            providerRunning: { false })
        _ = try? await controller.call(.init(.templates))
        XCTAssertEqual(launches, 1)
    }
}
