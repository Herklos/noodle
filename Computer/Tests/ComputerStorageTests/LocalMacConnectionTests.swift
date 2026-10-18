import AppKit
import Foundation
import Combine
import LocalMacCore
import ComputerCore
import XCTest
@testable import NoodleComputer

/// Exercise the real client transport against a bounded pipe peer. These tests
/// never register services, log into accounts or request desktop permissions.
@MainActor final class LocalMacConnectionTests: XCTestCase {
    private func peer(_ input: Pipe, _ output: Pipe, count: Int,
                      respond: @escaping (LocalMacRequest) async throws -> LocalMacReply) -> Task<[LocalMacRequest], Error> {
        Task.detached {
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            var requests: [LocalMacRequest] = []
            for _ in 0..<count {
                let data = try XCTUnwrap(LocalMacWire.read(input.fileHandleForReading))
                let request = try LocalMacWire.decode(LocalMacRequest.self, from: data)
                try request.validate(); requests.append(request)
                let reply = try await respond(request)
                try LocalMacWire.write(JSONEncoder().encode(reply), to: output.fileHandleForWriting)
            }
            return requests
        }
    }
    private nonisolated static func reply(_ request: LocalMacRequest, displayID: UInt32? = nil) -> LocalMacReply {
        var reply = LocalMacReply(id: request.id)
        var status = LocalMacStatus(screenCapture: true, accessibility: true, postEvents: true, display: .init())
        status.displayID = displayID; reply.status = status
        return reply
    }
    func testHandshakePrecedesCaptureAndTerminalRoundTrip() async throws {
        let input = Pipe(), output = Pipe()
        let terminal = UUID()
        let helper = peer(input, output, count: 3) { request in
            var reply = Self.reply(request, displayID: request.operation == .status ? nil : 99)
            if request.operation == .terminalRead { reply.terminalID = terminal; reply.data = Data("workspace % ".utf8); reply.offset = 12 }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        var read = LocalMacRequest(.terminalRead); read.terminalID = terminal
        let reply = try await runtime.call(read)
        XCTAssertEqual(reply.terminalID, terminal)
        XCTAssertEqual(String(data: reply.data!, encoding: .utf8), "workspace % ")
        let requests = try await helper.value
        XCTAssertEqual(requests.map(\.operation), [.status, .stream, .terminalRead])
        XCTAssertEqual(requests[1].protectedDisplayIDs, [2])
        runtime.close()
    }
    func testMissingPermissionKeepsConnectionUsableAndDefersCaptureUntilGranted() async throws {
        let input = Pipe(), output = Pipe()
        var granted = false
        let helper = peer(input, output, count: 4) { request in
            var reply = Self.reply(request)
            reply.status?.accessibility = granted
            reply.status?.postEvents = granted
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        XCTAssertTrue(runtime.isConnected)
        XCTAssertFalse(runtime.status?.canControl ?? true)
        await runtime.refreshStatus()
        XCTAssertTrue(runtime.isConnected)
        granted = true
        await runtime.refreshStatus()
        let requests = try await helper.value
        XCTAssertEqual(requests.map(\.operation), [.status, .status, .status, .stream])
        XCTAssertEqual(requests.last?.protectedDisplayIDs, [2])
        runtime.close()
    }

    func testOldHelperProducesActionableStartupFailure() async throws {
        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 1) { request in
            var reply = Self.reply(request); reply.protocolVersion = nil; return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        do {
            try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
            XCTFail("An unversioned helper must not start capture.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incompatible")) }
        XCTAssertFalse(runtime.isConnected)
        let requests = try await helper.value
        XCTAssertEqual(requests.count, 1)
    }
    func testMainDisplayAppearingStopsCaptureOnStatusPoll() async throws {
        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 3) { Self.reply($0, displayID: 99) }
        var displays: Set<UInt32> = [2]
        let runtime = LocalMacComputer(displayIDs: { displays })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        displays.insert(99)
        await runtime.refreshStatus()
        XCTAssertFalse(runtime.isConnected)
        XCTAssertTrue(runtime.error?.contains("separate") == true)
        _ = try await helper.value
    }

    /// Answers until the client closes, for requests the client sends by itself.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LocalMacRequest] = []
        func append(_ request: LocalMacRequest) { lock.lock(); values.append(request); lock.unlock() }
        var requests: [LocalMacRequest] { lock.lock(); defer { lock.unlock() }; return values }
        var streams: [LocalMacRequest] { requests.filter { $0.operation == .stream } }
    }
    private func openPeer(_ input: Pipe, _ output: Pipe, log: RequestLog,
                          respond: @escaping (LocalMacRequest) -> LocalMacReply) -> Task<Void, Error> {
        Task.detached {
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            while let data = try LocalMacWire.read(input.fileHandleForReading) {
                let request = try LocalMacWire.decode(LocalMacRequest.self, from: data)
                try request.validate(); log.append(request)
                try LocalMacWire.write(JSONEncoder().encode(respond(request)), to: output.fileHandleForWriting)
            }
        }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out")
    }
    func testLockedMacStartsWithoutCaptureUntilItsDisplaysReturn() async throws {
        let input = Pipe(), output = Pipe(), log = RequestLog()
        let helper = openPeer(input, output, log: log) { Self.reply($0, displayID: $0.operation == .stream ? 99 : nil) }
        var displays: Set<UInt32> = []
        let runtime = LocalMacComputer(displayIDs: { displays })
        var disconnects: [String] = []; runtime.onDisconnect = { disconnects.append($0) }
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [])
        XCTAssertTrue(runtime.isConnected)
        XCTAssertEqual(log.requests.map(\.operation), [.status])
        // No view polls here: capture must come back on its own.
        displays = [2]
        try await waitUntil { !log.streams.isEmpty }
        XCTAssertEqual(log.streams.map(\.enabled), [true])
        XCTAssertEqual(log.streams.first?.protectedDisplayIDs, [2])
        XCTAssertTrue(disconnects.isEmpty)
        runtime.close()
        try await helper.value
    }
    func testLockingTheMacPausesCaptureAndKeepsTheConnection() async throws {
        let input = Pipe(), output = Pipe(), log = RequestLog()
        let frame = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]))
        var streaming = false
        let helper = openPeer(input, output, log: log) { request in
            if request.operation == .stream { streaming = request.enabled == true }
            var reply = Self.reply(request, displayID: streaming ? 99 : nil)
            if streaming { reply.frame = true; reply.data = frame }
            return reply
        }
        var displays: Set<UInt32> = [2]
        let runtime = LocalMacComputer(displayIDs: { displays })
        var disconnects: [String] = []; runtime.onDisconnect = { disconnects.append($0) }
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        XCTAssertNotNil(runtime.image)

        displays = []
        await runtime.refreshStatus()
        XCTAssertNil(runtime.image, "Frames must not be shown while the main desktop's displays are unknown.")
        try await waitUntil { log.streams.count == 2 && runtime.status?.displayID == nil }
        XCTAssertEqual(log.streams.map(\.enabled), [true, false])
        XCTAssertTrue(runtime.isConnected)
        XCTAssertNil(runtime.error)
        XCTAssertNil(runtime.image)
        var read = LocalMacRequest(.terminalRead); read.terminalID = UUID()
        _ = try await runtime.call(read)

        displays = [2]
        try await waitUntil { log.streams.count == 3 && runtime.image != nil }
        XCTAssertEqual(log.streams.map(\.enabled), [true, false, true])
        XCTAssertEqual(log.streams.last?.protectedDisplayIDs, [2])
        XCTAssertTrue(disconnects.isEmpty)
        runtime.close()
        try await helper.value
    }
    func testMainDisplayCaptureStillDisconnectsWhileTheMacIsLocked() async throws {
        let input = Pipe(), output = Pipe()
        var replies = 0
        let helper = peer(input, output, count: 3) { request in
            replies += 1
            return Self.reply(request, displayID: ([nil, 99, 2] as [UInt32?])[replies - 1])
        }
        var displays: Set<UInt32> = [2]
        let runtime = LocalMacComputer(displayIDs: { displays })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        displays = []
        await runtime.refreshStatus()
        XCTAssertFalse(runtime.isConnected)
        XCTAssertTrue(runtime.error?.contains("separate") == true)
        _ = try await helper.value
    }
    func testExpectedDisconnectDoesNotShowAnError() async throws {
        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 3) { request in
            var reply = Self.reply(request)
            if request.operation == .terminalRead { reply.id = nil; reply.error = "Desktop ended" }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        var unexpected = false; runtime.onDisconnect = { _ in unexpected = true }
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        runtime.expectDisconnect(true)
        var read = LocalMacRequest(.terminalRead); read.terminalID = UUID()
        do { _ = try await runtime.call(read); XCTFail("Disconnected request must fail.") } catch {}
        XCTAssertFalse(unexpected); XCTAssertNil(runtime.error); XCTAssertFalse(runtime.isConnected)
        _ = try await helper.value
    }
    func testPermissionErrorClearsOnlyWhenAccessibilityAndEventPostingRecover() async throws {
        let input = Pipe(), output = Pipe()
        var replyNumber = 0
        let helper = peer(input, output, count: 5) { request in
            replyNumber += 1
            var reply = Self.reply(request, displayID: 99)
            reply.status?.accessibility = replyNumber >= 3
            reply.status?.postEvents = replyNumber >= 4
            if request.operation == .input { reply.status = nil; reply.error = LocalMacStatus.inputPermissionError }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        runtime.expectDisconnect(true)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        let failed = expectation(description: "Input denial received")
        let observer = runtime.$error.sink { if $0 == LocalMacStatus.inputPermissionError { failed.fulfill() } }
        runtime.send(LocalMacInput(.move))
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        await runtime.refreshStatus()
        XCTAssertTrue(runtime.status?.accessibility == true)
        XCTAssertFalse(runtime.status?.canControl == true)
        XCTAssertEqual(runtime.error, LocalMacStatus.inputPermissionError)
        await runtime.refreshStatus()
        XCTAssertTrue(runtime.status?.canControl == true)
        XCTAssertNil(runtime.error)
        _ = try await helper.value
        runtime.close()
    }
    func testPermissionRecoveryPreservesAnUnrelatedFailure() async throws {
        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 4) { request in
            var reply = Self.reply(request, displayID: 99)
            if request.operation == .input { reply.status = nil; reply.error = LocalMacStatus.inputPermissionError }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        runtime.expectDisconnect(true)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        let failed = expectation(description: "Input denial received")
        let observer = runtime.$error.sink { if $0 == LocalMacStatus.inputPermissionError { failed.fulfill() } }
        runtime.send(LocalMacInput(.move))
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        runtime.error = "A separate capture failure"
        await runtime.refreshStatus()
        XCTAssertEqual(runtime.error, "A separate capture failure")
        _ = try await helper.value
        runtime.close()
    }
    func testSessionIgnoresOldConnectionsAndExpectedStops() {
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        let previous = LocalMacComputer(), current = LocalMacComputer()
        session.localMac = current; session.phase = .running
        session.localMacDisconnected(previous, reason: "stale")
        XCTAssertEqual(session.phase, .running)
        session.phase = .stopping
        session.localMacDisconnected(current, reason: "normal shutdown")
        XCTAssertEqual(session.phase, .stopping)
        session.phase = .running
        session.localMacDisconnected(current, reason: "lost")
        XCTAssertEqual(session.phase, .failed("lost"))
        session.phase = .starting
        session.localMacDisconnected(current, reason: "startup lost")
        XCTAssertEqual(session.phase, .failed("startup lost"))
    }

    func testRestartReplacesTerminalAndFileConnections() async throws {
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        let previous = LocalMacComputer()
        session.localMac = previous
        let terminal = GuestTerminal()
        let connection = LocalMacTerminalConnection(runtime: previous, terminal: terminal)
        connection.id = UUID()
        session.localTerminal = connection; session.terminal = terminal
        let oldFiles = session.filesModel(for: previous)
        oldFiles.error = "The desktop connection is unavailable or busy."
        session.phase = .failed("Desktop capture stopped")

        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 3) { request in
            var reply = Self.reply(request, displayID: 99)
            if request.operation == .fileHome { reply.homeDirectory = "/Users/retained" }
            return reply
        }
        let current = LocalMacComputer(displayIDs: { [2] })
        current.expectDisconnect(true)
        try await current.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        session.localMac = current; session.phase = .running
        defer { current.close() }

        XCTAssertNil(session.localTerminal)
        XCTAssertNil(session.terminal)
        XCTAssertNil(connection.id)
        let files = session.filesModel(for: current)
        XCTAssertFalse(files === oldFiles)
        XCTAssertNil(files.error)
        let home = try await files.service.homeDirectory()
        XCTAssertEqual(home, "/Users/retained")
        let requests = try await helper.value
        XCTAssertEqual(requests.map(\.operation), [.status, .stream, .fileHome])
    }

    func testSameConnectionPreservesSurfacesAndRemovalClosesThem() {
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        let runtime = LocalMacComputer()
        session.localMac = runtime
        let terminal = GuestTerminal()
        let connection = LocalMacTerminalConnection(runtime: runtime, terminal: terminal)
        connection.id = UUID()
        session.localTerminal = connection; session.terminal = terminal
        let files = session.filesModel(for: runtime)
        files.folder = "/workspace/Documents"

        session.localMac = runtime
        XCTAssertTrue(session.localTerminal === connection)
        XCTAssertTrue(session.terminal === terminal)
        XCTAssertTrue(session.filesModel(for: runtime) === files)
        XCTAssertEqual(files.folder, "/workspace/Documents")
        XCTAssertNotNil(connection.id)

        session.localMac = nil
        XCTAssertNil(session.localTerminal)
        XCTAssertNil(session.terminal)
        XCTAssertNil(connection.id)
    }

    func testTerminalOpeningCannotRestoreAnOldConnectionAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        let replacement = LocalMacComputer()
        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 3) { request in
            var reply = Self.reply(request, displayID: 99)
            if request.operation == .terminalOpen {
                await MainActor.run { session.localMac = replacement }
                reply.terminalID = UUID()
            }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        runtime.expectDisconnect(true)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        defer { runtime.close() }
        session.localMac = runtime; session.phase = .running

        await store.selectDisplay(.terminal, in: session)

        XCTAssertTrue(session.localMac === replacement)
        XCTAssertNil(session.localTerminal)
        XCTAssertNil(session.terminal)
        XCTAssertEqual(session.displayMode, .desktop)
        XCTAssertFalse(session.openingTerminal)
        XCTAssertNil(store.error)
        let requests = try await helper.value
        XCTAssertEqual(requests.map(\.operation), [.status, .stream, .terminalOpen])
    }

    /// Agents share a Local Mac's 16 running shells; the person's own terminal never counts.
    func testAgentShellsAreLimitedButThePersonsTerminalAlwaysOpens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let provider = try ComputerProvider(store: store, socket: root.appendingPathComponent("computer.sock"), listens: false)
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        store.sessions = [session]
        let ids = (0..<20).map { _ in UUID() }
        let input = Pipe(), output = Pipe()
        // Serves until the app disconnects; the first agent's shell has ended.
        let helper = Task.detached { () -> [LocalMacOperation] in
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            var operations: [LocalMacOperation] = [], opened = 0
            while let data = try? LocalMacWire.read(input.fileHandleForReading),
                  let request = try? LocalMacWire.decode(LocalMacRequest.self, from: data) {
                operations.append(request.operation)
                var reply = Self.reply(request, displayID: request.operation == .status ? nil : 99)
                if request.operation == .terminalOpen { reply.terminalID = ids[opened]; opened += 1 }
                if request.operation == .terminalRead {
                    reply.terminalID = request.terminalID; reply.offset = 0; reply.exited = request.terminalID == ids[0]
                }
                try? LocalMacWire.write(JSONEncoder().encode(reply), to: output.fileHandleForWriting)
            }
            return operations
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        runtime.expectDisconnect(true)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        session.localMac = runtime; session.phase = .running
        let agents = (0..<18).map { _ in UUID() }
        func open(_ agent: UUID) async throws -> UUID? {
            try await provider.handle(.init(.terminalOpen, computerID: session.id, agentID: agent), peer: "agents").terminalID
        }

        for agent in agents[0..<16] { _ = try await open(agent) }
        do { _ = try await open(agents[16]); XCTFail("A 17th agent shell opened") } catch {}
        await store.selectDisplay(.terminal, in: session)
        XCTAssertNotNil(session.localTerminal)
        XCTAssertNil(store.error)
        let read = try await provider.handle(.init(.terminalRead, computerID: session.id, agentID: agents[0], terminalID: ids[0]), peer: "agents")
        XCTAssertEqual(read.exited, true)
        let replacement = try await open(agents[17])
        XCTAssertEqual(replacement, ids[17])

        session.localTerminal?.close()
        runtime.close()
        let operations = await helper.value
        XCTAssertEqual(operations.filter { $0 == .terminalOpen }.count, 18)
    }
}
