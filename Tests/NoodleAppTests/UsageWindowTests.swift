import AppKit
import NoodleCore
import NoodleRuntimeSettings
import SwiftUI
import XCTest
@testable import NoodleRuntime

@MainActor final class UsageWindowTests: XCTestCase {
    /// A closed Usage window stays alive for reopening, so it must not keep reading the ledger.
    func testClosedWindowStopsReadingTheLedgerUntilReopened() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let history = UsageHistory(url: folder.appendingPathComponent("usage.sqlite"))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UsageView(history: history, agents: []))
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        window.orderBack(nil)
        try await wait { history.queries > 0 }

        window.close()
        try await settle()
        let closed = history.queries
        for _ in 0..<3 {
            history.record(UsageSample(date: Date(), agentID: UUID(), agentName: "Alfred", harness: "codex",
                model: "gpt", tokens: UsageTokens(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, reasoning: 0), costUSD: nil))
            try await settle()
        }
        XCTAssertEqual(history.queries, closed)

        window.orderBack(nil)
        try await wait { history.queries > closed }
    }

    private func settle() async throws {
        for _ in 0..<20 {
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded() }
            guard ContinuousClock.now < deadline else {
                XCTFail("Condition not met", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
