import AppletBridge
import AppletCore
import XCTest

@testable import NoodleApplet

/// A bot that opens a noodlet and forgets it is asked, once it sits unused, to close it.
@MainActor final class IdleTests: XCTestCase {
  private let session = UUID(), agent = UUID(), start = Date(timeIntervalSince1970: 1_000_000)
  private func minutes(_ value: Double) -> Date { start.addingTimeInterval(value * 60) }
  private let unwatched: (UUID) -> AppletIdleWatch.Running? = { _ in .init(name: "Snake", watched: false) }

  func testASessionABotLeftRunningUnusedIsReportedOncePerIdleStretch() {
    var watch = AppletIdleWatch()
    watch.started(session, caller: "noodle", agentID: agent, at: start)
    watch.used(session, at: minutes(10))
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(29), running: unwatched), [], "Not running long enough")
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(24.5), running: unwatched), [], "Used too recently")
    let due = watch.due(for: "noodle", at: minutes(31), running: unwatched)
    XCTAssertEqual(due.map(\.sessionID), [session])
    XCTAssertEqual(due.first?.agentID, agent)
    XCTAssertEqual(due.first?.note, "The noodlet Snake (session \(session.uuidString)) has been running for 31 minutes and nothing has used it for 21. If you no longer need it, close it; its data stays.")
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(45), running: unwatched), [], "Reported once")
    watch.used(session, at: minutes(46))
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(60), running: unwatched), [])
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(61), running: unwatched).map(\.sessionID), [session], "Used again, then left again")
  }

  func testOnlyTheAppWhoseBotStartedItIsTold() {
    var watch = AppletIdleWatch()
    watch.started(session, caller: "noodle", agentID: agent, at: start)
    XCTAssertEqual(watch.due(for: "hub", at: minutes(60), running: unwatched), [])
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(60), running: unwatched).count, 1)
  }

  func testAClosedSessionIsForgotten() {
    var watch = AppletIdleWatch()
    watch.started(session, caller: "noodle", agentID: agent, at: start)
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(5), running: { _ in nil }), [])
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(60), running: unwatched), [])
  }

  func testASessionSomeoneIsWatchingIsInUse() {
    var watch = AppletIdleWatch()
    watch.started(session, caller: "noodle", agentID: agent, at: start)
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(40), running: { _ in .init(name: "Snake", watched: true) }), [])
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(50), running: unwatched), [], "Watching counted as use")
    XCTAssertEqual(watch.due(for: "noodle", at: minutes(55), running: unwatched).count, 1)
  }

  /// Only the session the bot opened is reported, to the app it came through, and a closed one never.
  func testTheAppIsToldOfNoodletsItsBotsLeftRunning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "Idle." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    let library = botLibrary(root: root, defaults: defaults)
    let runtime = AppletRuntime(library: library, defaults: defaults)
    var clock = start
    runtime.now = { clock }
    let noodle = AppletBuildIdentity.current.noodleID, hub = AppletBuildIdentity.current.hubID
    func open(_ title: String, agent: UUID?) async throws -> UUID {
      var request = AppletRequest(.open)
      request.path = try botNoodlet([
        "noodlet.json": try JSONEncoder().encode(NoodletManifest(title: title)),
        "index.html": Data("<title>\(title)</title>".utf8),
      ], named: title, owner: "author", root: root)
      request.owner = "author"
      request.agentID = agent
      let response = try await runtime.handle(request, identity: noodle).checked()
      return try XCTUnwrap(response.sessionID)
    }
    let bots = try await open("Snake", agent: agent)
    let people = try await open("Tetris", agent: nil)
    addTeardownBlock { @MainActor in runtime.shutdown() }
    func idle(_ caller: String) async throws -> [AppletIdleNotice]? {
      try await runtime.handle(AppletRequest(.idle), identity: caller).checked().idle
    }

    clock = minutes(31)
    let other = try await idle(hub)
    XCTAssertNil(other, "Another app's bot")
    let due = try await idle(noodle)
    XCTAssertEqual(due?.map(\.sessionID), [bots])
    XCTAssertEqual(due?.first?.agentID, agent)
    XCTAssertNotEqual(bots, people)
    let again = try await idle(noodle)
    XCTAssertNil(again, "Told once")

    _ = try await runtime.handle(AppletRequest(.status, sessionID: bots), identity: noodle).checked()
    clock = minutes(47)
    let left = try await idle(noodle)
    XCTAssertNotNil(left, "Used, then left again")
    _ = try await runtime.handle(AppletRequest(.close, sessionID: bots), identity: noodle).checked()
    clock = minutes(90)
    let closed = try await idle(noodle)
    XCTAssertNil(closed, "Closed")
  }
}
