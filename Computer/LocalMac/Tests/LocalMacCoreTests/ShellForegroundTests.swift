import Darwin
import Foundation
import LocalMacPrivate
import XCTest
@testable import LocalMacCore

final class ShellForegroundTests: XCTestCase {
    /// A Local Mac shell leads a session on its own terminal, as in Terminal: the helper, outside
    /// that session, sees whether a command holds the terminal, and Control-C reaches the command.
    func testAShellOwnsItsTerminalSoItsCommandsCanBeSeenAndInterrupted() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        // An existing .zshrc, as the account has, keeps zsh from asking a new user to set it up.
        try Data().write(to: home.appendingPathComponent(".zshrc"))
        defer { try? FileManager.default.removeItem(at: home) }

        var master: Int32 = -1
        let shell = NLMSpawnTerminal(home.path, &master)
        XCTAssertGreaterThan(shell, 0)
        guard shell > 0 else { return }
        defer { kill(shell, SIGKILL); var status: Int32 = 0; waitpid(shell, &status, 0); close(master) }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        XCTAssertEqual(LocalMacShellForeground.runsCommand(master: master, shell: shell), false, "the shell has its terminal")

        func send(_ text: String) { _ = text.utf8CString.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count - 1) } }
        // Waits on the shell, not a clock: the deadline only ends a test that already failed.
        func becomes(_ expected: Bool) -> Bool {
            let deadline = Date().addingTimeInterval(30)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline {
                while read(master, &buffer, buffer.count) > 0 {}
                if LocalMacShellForeground.runsCommand(master: master, shell: shell) == expected { return true }
                usleep(20_000)
            }
            return false
        }
        send("sleep 30\r")
        XCTAssertTrue(becomes(true), "a running command holds the terminal")
        send("\u{3}")
        XCTAssertTrue(becomes(false), "Control-C ends it and the shell has its terminal again")
    }
}
