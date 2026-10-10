import Darwin
import Foundation
import XCTest
@testable import LocalMacCore

final class LoginRecordsTests: XCTestCase {
    private var database: String!

    override func setUpWithError() throws {
        database = FileManager.default.temporaryDirectory.appendingPathComponent("utmpx-\(UUID())").path
        XCTAssertTrue(FileManager.default.createFile(atPath: database, contents: nil))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: database) }

    private func login(_ user: String, id: String, pid: Int32) {
        var record = utmpx()
        record.ut_type = Int16(USER_PROCESS)
        record.ut_pid = pid
        fill(&record.ut_user, user); fill(&record.ut_line, "console"); fill(&record.ut_id, id)
        gettimeofday(&record.ut_tv, nil)
        _ = utmpxname(database)
        setutxent(); XCTAssertNotNil(pututxline(&record)); endutxent()
        _ = utmpxname(nil)
    }

    private func fill<T>(_ field: inout T, _ text: String) {
        withUnsafeMutableBytes(of: &field) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            let utf8 = Array(text.utf8.prefix(bytes.count - 1))
            bytes.copyBytes(from: utf8)
        }
    }

    /// The users whose logins are open in the test database.
    private func signedIn() -> [String] {
        _ = utmpxname(database)
        defer { endutxent(); _ = utmpxname(nil) }
        setutxent()
        var users: [String] = []
        while let entry = getutxent() {
            var record = entry.pointee
            guard record.ut_type == Int16(USER_PROCESS) else { continue }
            users.append(withUnsafeBytes(of: &record.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        }
        return users.sorted()
    }

    func testStopEndsOnlyTheStoppedAccountsLogins() {
        login("person", id: "p1", pid: 100)
        login("noodle_abc", id: "n1", pid: 200)
        login("noodle_abc", id: "n2", pid: 201)
        XCTAssertEqual(signedIn(), ["noodle_abc", "noodle_abc", "person"])
        XCTAssertEqual(LocalMacLoginRecords.close(user: "noodle_abc", database: database), 2)
        XCTAssertEqual(signedIn(), ["person"])
        XCTAssertEqual(LocalMacLoginRecords.close(user: "noodle_abc", database: database), 0)
    }
}
