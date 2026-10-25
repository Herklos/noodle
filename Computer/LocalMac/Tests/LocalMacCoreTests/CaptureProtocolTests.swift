import Foundation
import XCTest
@testable import LocalMacCore

final class CaptureProtocolTests: XCTestCase {
    func testCaptureRequiresASeparateDisplayRegardlessOfResolution() throws {
        try LocalMacCapturePolicy.validate(displayID: 99, isBuiltin: false, protectedIDs: [2, 3])
        for id in [0, 2, 3] as [UInt32] {
            XCTAssertThrowsError(try LocalMacCapturePolicy.validate(displayID: id, isBuiltin: false, protectedIDs: [2, 3]))
        }
        XCTAssertThrowsError(try LocalMacCapturePolicy.validate(displayID: 99, isBuiltin: true, protectedIDs: [2]))
        for ids in [[], [0], [2, 2], Array(1...33)] as [[UInt32]] {
            XCTAssertThrowsError(try LocalMacCapturePolicy.validateProtectedDisplays(ids))
        }
    }
    func testNoSingleDisplayListsWhatTheAccountSees() {
        typealias Seen = LocalMacCapturePolicy.SeenDisplay
        let none = LocalMacCapturePolicy.noSingleDisplay([], protectedIDs: [1])
        XCTAssertEqual(none.message, "This account has no display of its own to show.\nIt sees no displays.")
        XCTAssertEqual(none.log, "This account has no display of its own to show. It sees no displays. Main desktop displays: 1.")
        let shared = LocalMacCapturePolicy.noSingleDisplay([Seen(id: 1, isBuiltin: true, width: 1512, height: 982),
            Seen(id: 4, isBuiltin: false, width: 2560, height: 1440)], protectedIDs: [1, 4])
        XCTAssertEqual(shared.message, "This account has no display of its own to show.\n"
            + "Displays it sees: 1 (built-in, 1512 × 982, main desktop); 4 (2560 × 1440, main desktop).")
        XCTAssertEqual(shared.log, "This account has no display of its own to show. "
            + "Displays it sees: 1 (built-in, 1512 × 982, main desktop); 4 (2560 × 1440, main desktop). Main desktop displays: 1, 4.")
        let builtin = LocalMacCapturePolicy.noSingleDisplay([Seen(id: 7, isBuiltin: true, width: 1280, height: 800)], protectedIDs: [4])
        XCTAssertEqual(builtin.message, "This account has no display of its own to show.\nDisplays it sees: 7 (built-in, 1280 × 800).")
        let several = LocalMacCapturePolicy.noSingleDisplay([Seen(id: 5, isBuiltin: false, width: 1280, height: 800),
            Seen(id: 6, isBuiltin: false, width: 1280, height: 800), Seen(id: 4, isBuiltin: false, width: 2560, height: 1440)],
            protectedIDs: [4])
        XCTAssertEqual(several.message, "This account has more than one display of its own, so none is shown.\n"
            + "Displays it sees: 5 (1280 × 800); 6 (1280 × 800); 4 (2560 × 1440, main desktop).")
    }
    func testCaptureAuthorizationSurvivesWireRoundTrip() throws {
        var request = LocalMacRequest(.stream); request.enabled = true
        XCTAssertThrowsError(try request.validate())
        request.protectedDisplayIDs = [2, 3]
        let decoded = try LocalMacWire.decode(LocalMacRequest.self, from: JSONEncoder().encode(request))
        try decoded.validate()
        XCTAssertEqual(decoded.protectedDisplayIDs, [2, 3])
        request.enabled = false; request.protectedDisplayIDs = nil
        XCTAssertNoThrow(try request.validate())
    }
    func testLegacyAndFuturePeersFailBeforeDecodingOrExecutingOperations() throws {
        for version in [nil, 0, LocalMacWire.version + 1] as [Int?] {
            var payload: [String: Any] = ["operation": "futureUnsupportedOperation"]
            payload["protocolVersion"] = version
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertThrowsError(try LocalMacWire.decode(LocalMacRequest.self, from: data)) {
                XCTAssertTrue($0.localizedDescription.contains("incompatible"))
            }
            XCTAssertThrowsError(try LocalMacWire.decode(LocalMacReply.self, from: data)) {
                XCTAssertTrue($0.localizedDescription.contains("incompatible"))
            }
        }
        let reply = LocalMacReply(id: UUID())
        XCTAssertEqual(try LocalMacWire.decode(LocalMacReply.self, from: JSONEncoder().encode(reply)).id, reply.id)
    }
}
