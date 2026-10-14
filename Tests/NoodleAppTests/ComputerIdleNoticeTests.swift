import ComputerBridge
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class ComputerIdleNoticeTests: XCTestCase {
    func testNoodleHandsOnWhatNoodleComputerSaysItsBotsLeftUnused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-idle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root); try repository.prepare()
        let notice = ComputerIdleNotice(computerID: UUID(), agentID: UUID(), note: "Build box is unused")
        let controller = ComputerController(repository: repository, applicationLookup: { nil }, connection: { request in
            var response = ComputerResponse(); response.capabilities = ComputerCapabilities()
            if request.operation == .idle { response.idle = [notice] }
            return response
        })
        var told: [ComputerIdleNotice] = []
        controller.onIdle = { told += $0 }
        await controller.checkIdle()
        XCTAssertEqual(told, [notice])
    }
}
