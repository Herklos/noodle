import XCTest
@testable import NoodleCore

final class VerifiedExecutablesTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("verified-\(UUID())")
        try Data("first".utf8).write(to: file)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: file) }

    func testAPassedCheckIsRememberedUntilTheFileChanges() throws {
        var checks = 0
        let check = { checks += 1 }
        try VerifiedExecutables.verify(file, requirement: "rule", check: check)
        try VerifiedExecutables.verify(file, requirement: "rule", check: check)
        XCTAssertEqual(checks, 1)

        try VerifiedExecutables.verify(file, requirement: "other rule", check: check)
        XCTAssertEqual(checks, 2, "Each requirement is checked on its own")

        // The same size, written in place, as a tampered file might be.
        try Data("other".utf8).write(to: file)
        try VerifiedExecutables.verify(file, requirement: "rule", check: check)
        XCTAssertEqual(checks, 3)

        try FileManager.default.removeItem(at: file)
        try Data("other".utf8).write(to: file)
        try VerifiedExecutables.verify(file, requirement: "rule", check: check)
        XCTAssertEqual(checks, 4, "A replaced file is checked again")
    }

    func testAFailedCheckIsNeverRemembered() {
        struct Refused: Error {}
        var checks = 0
        for _ in 0..<2 {
            XCTAssertThrowsError(try VerifiedExecutables.verify(file, requirement: "refused") { checks += 1; throw Refused() })
        }
        XCTAssertEqual(checks, 2)
    }
}
