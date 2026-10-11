import ComputerBridge
import Darwin
import XCTest
@testable import NoodleCore

final class ComputerTransferTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testBinaryAndEmptyFilesAreStagedWithoutInlinePayloads() throws {
        let root = try directory(), shared = try directory()
        for size in [0, 2_500_017] {
            let name = "binary ' $()\n \(size).dat"
            let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            try bytes.write(to: root.appendingPathComponent(name))
            let staging = try ComputerTransferFiles.staging(root: shared, id: UUID(), create: true)
            XCTAssertEqual(try ComputerWorkspaceFiles.upload(workspace: root, path: name, to: staging), Int64(size))
            XCTAssertEqual(try Data(contentsOf: staging), bytes)
        }
    }

    func testRefusesEscapeSymlinksMissingParentsAndSpecialFiles() throws {
        let root = try directory(), outside = try directory()
        try Data([7]).write(to: outside.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file"), withDestinationURL: outside.appendingPathComponent("secret"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path, 0o600), 0)
        for path in ["../secret", outside.appendingPathComponent("secret").path, "link/secret", "file", "fifo", "missing/file", "", "a\0b"] {
            XCTAssertThrowsError(try ComputerWorkspaceFiles.upload(workspace: root, path: path, to: root.appendingPathComponent(UUID().uuidString)))
        }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("secret")), Data([7]))
    }

    func testOversizedSparseFileIsRejectedBeforeCopying() throws {
        let root = try directory(), source = root.appendingPathComponent("large")
        let fd = Darwin.open(source.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        XCTAssertEqual(ftruncate(fd, ComputerTransferFiles.limit + 1), 0)
        XCTAssertThrowsError(try ComputerWorkspaceFiles.upload(workspace: root, path: "large", to: root.appendingPathComponent("staging")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("staging").path))
    }

    func testLocalPathResolutionAndTransferDeadline() throws {
        let root = try directory().resolvingSymlinksInPath()
        XCTAssertEqual(try ComputerWorkspaceFiles.relativePath("a.bin", currentDirectory: root, workspace: root), "a.bin")
        XCTAssertEqual(try ComputerWorkspaceFiles.relativePath("b.bin", currentDirectory: root.appendingPathComponent("sub"), workspace: root), "sub/b.bin")
        XCTAssertEqual(try ComputerWorkspaceFiles.relativePath(root.appendingPathComponent("a.bin").path, currentDirectory: root, workspace: root), "a.bin")
        for path in ["/etc/passwd", "../escape", "link/../file", ""] {
            XCTAssertThrowsError(try ComputerWorkspaceFiles.relativePath(path, currentDirectory: root, workspace: root))
        }
        XCTAssertEqual(ComputerOperation.fileUpload.timeout, 600, "transfers keep their ten-minute limit")
    }
}
