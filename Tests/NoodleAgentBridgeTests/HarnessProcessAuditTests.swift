import Darwin
import Foundation
import NoodleAgentBridge
import XCTest

final class HarnessProcessAuditTests: XCTestCase {
    private final class System {
        var processes: [pid_t: HarnessProcessAudit.Process] = [:]
        var time = Date(timeIntervalSince1970: 0)
        var lines: [String] = []
    }

    private func audit(_ system: System) -> HarnessProcessAudit {
        HarnessProcessAudit(bot: "7de317f8", name: "Sonia", harness: "codex", group: 100,
                            processes: { _, _ in system.processes }, now: { system.time },
                            record: { system.lines.append($0) })
    }

    private func process(_ parent: pid_t, _ executable: String, peak: UInt64 = 0) -> HarnessProcessAudit.Process {
        HarnessProcessAudit.Process(parent: parent, executable: executable, peakFootprint: peak)
    }

    func testEachCommandIsTracedToItsBot() {
        let system = System()
        let audit = audit(system)
        system.processes = [100: process(1, "/opt/codex")]
        audit.scan()
        system.processes[200] = process(100, "/usr/bin/perl", peak: 28 * 1_024 * 1_024 * 1_024)
        system.time += 2_801
        audit.scan()
        system.processes[200] = nil
        system.time += 4
        audit.scan()
        XCTAssertEqual(system.lines, [
            "bot=7de317f8 name=Sonia harness=codex pid=100 parent=1 started /opt/codex",
            "bot=7de317f8 name=Sonia harness=codex pid=200 parent=100 started /usr/bin/perl",
            "bot=7de317f8 name=Sonia harness=codex pid=200 ended /usr/bin/perl after 4s peak 28672 MB",
        ])
    }

    func testAnExecIsRecordedUnderTheSameProcess() {
        let system = System()
        let audit = audit(system)
        system.processes = [200: process(100, "/bin/zsh")]
        audit.scan()
        system.processes[200] = process(100, "/usr/bin/perl")
        audit.scan()
        XCTAssertEqual(system.lines.last, "bot=7de317f8 name=Sonia harness=codex pid=200 exec /usr/bin/perl")
    }

    func testThePeakIsTheHighestSeen() {
        let system = System()
        let audit = audit(system)
        system.processes = [200: process(100, "/usr/bin/perl", peak: 3 * 1_048_576)]
        audit.scan()
        system.processes[200] = process(100, "/usr/bin/perl", peak: 1_048_576)
        audit.scan()
        system.processes = [:]
        audit.scan()
        XCTAssertEqual(system.lines.last, "bot=7de317f8 name=Sonia harness=codex pid=200 ended /usr/bin/perl after 0s peak 3 MB")
    }

    func testFinishingRecordsEveryProcessThatEnded() {
        let system = System()
        let audit = audit(system)
        system.processes = [100: process(1, "/opt/codex"), 200: process(100, "/bin/zsh")]
        audit.scan()
        system.processes = [:]
        audit.finish()
        XCTAssertEqual(system.lines.filter { $0.contains(" ended ") }.count, 2)
        system.processes = [300: process(100, "/bin/zsh")]
        audit.scan()
        XCTAssertEqual(system.lines.count, 4, "A finished audit records nothing more.")
    }

    func testTheSystemLookupFindsTheGroupsCommands() throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var pid: pid_t = 0
        let command: [String] = ["/bin/sh", "-c", "/bin/sleep 30 & wait"]
        let arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sh", nil, &attributes, arguments, environ), 0)
        defer { kill(-pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
        var found: [pid_t: HarnessProcessAudit.Process] = [:]
        for _ in 0..<200 where !found.values.contains(where: { $0.executable == "/bin/sleep" }) {
            found = HarnessProcessAudit.system(group: pid, known: [])
            usleep(10_000)
        }
        XCTAssertNotNil(found[pid], "/bin/sh runs as /bin/bash, so only the group leader's presence is checked.")
        let child = try XCTUnwrap(found.first { $0.value.executable == "/bin/sleep" })
        XCTAssertEqual(child.value.parent, pid)
        XCTAssertGreaterThan(found[pid]?.peakFootprint ?? 0, 0)
    }
}
