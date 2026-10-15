import XCTest
@testable import ComputerCore

final class SSHDestinationTests: XCTestCase {
    func testAddressesParseLikeSSH() throws {
        XCTAssertEqual(try SSHDestination(address: "deploy@build.example.com"), SSHDestination(host: "build.example.com", port: 22, user: "deploy"))
        XCTAssertEqual(try SSHDestination(address: " pi@raspberry:2222 "), SSHDestination(host: "raspberry", port: 2222, user: "pi"))
        XCTAssertEqual(try SSHDestination(address: "root@[fd7a:115c:a1e0::1]:22"), SSHDestination(host: "fd7a:115c:a1e0::1", port: 22, user: "root"))
        XCTAssertEqual(try SSHDestination(address: "root@fd7a:115c::1"), SSHDestination(host: "fd7a:115c::1", port: 22, user: "root"))
        XCTAssertEqual(try SSHDestination(address: "me@100.101.102.103"), SSHDestination(host: "100.101.102.103", port: 22, user: "me"))
        // The last @ separates the user, as in ssh, so a user name may contain one.
        XCTAssertEqual(try SSHDestination(address: "me@corp@jump"), SSHDestination(host: "jump", port: 22, user: "me@corp"))
    }

    func testAddressesNeedAUserAndAHost() {
        for address in ["", "server", "@server", "me@", "me@server:0", "me@server:70000", "me@server:x", "me@ser ver", "me@[::1", "-oProxyCommand=x@server"] {
            XCTAssertThrowsError(try SSHDestination(address: address), address)
        }
    }

    func testAddressRoundTrips() throws {
        for address in ["deploy@build", "pi@raspberry:2222", "root@[fd7a::1]:2200", "root@[fd7a::1]"] {
            let destination = try SSHDestination(address: address)
            XCTAssertEqual(try SSHDestination(address: destination.address), destination)
        }
        XCTAssertEqual(SSHDestination(host: "build", port: 22, user: "deploy").address, "deploy@build")
    }

    func testSSHComputersNeedADestination() throws {
        var computer = Computer(name: "Server", kind: .ssh)
        XCTAssertThrowsError(try computer.validate())
        computer.ssh = SSHDestination(host: "server", port: 22, user: "me")
        XCTAssertNoThrow(try computer.validate())
        XCTAssertFalse(computer.hasDisplay)
        XCTAssertFalse(computer.usesVirtualMachine)
        computer.ssh?.user = ""
        XCTAssertThrowsError(try computer.validate())
    }

    func testSSHComputersSurviveTheLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ComputerLibrary(root: root)
        var computer = Computer(name: "Server", kind: .ssh)
        computer.ssh = SSHDestination(host: "server", port: 2200, user: "me", hostKey: "ssh-ed25519 AAAA", credential: .key)
        try FileManager.default.createDirectory(at: library.stagingDirectory(for: computer.id), withIntermediateDirectories: true)
        try library.commit(computer)
        XCTAssertEqual(try library.load().first?.ssh, computer.ssh)
    }
}
