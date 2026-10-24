import BrowserBridge
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class BrowserIdleNoticeTests: XCTestCase {
    func testNoodleHandsOnWhatNoodleBrowserSaysItsBotsLeftUnused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-browser-idle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root); try repository.prepare()
        let notice = BrowserIdleNotice(agentID: UUID(), tabIDs: [UUID()], note: "Docs is unused")
        let controller = BrowserController(repository: repository, connection: { request in
            var response = BrowserResponse()
            if request.operation == .idle { response.idle = [notice] }
            return response
        })
        var told: [BrowserIdleNotice] = []
        controller.onIdle = { told += $0 }
        await controller.checkIdle()
        XCTAssertEqual(told, [notice])
    }
}
