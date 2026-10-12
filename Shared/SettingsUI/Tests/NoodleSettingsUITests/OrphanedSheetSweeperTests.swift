import AppKit
import SwiftUI
import XCTest
@testable import NoodleSettingsUI

/// How a sheet got left behind was never reproduced, so a window stands in for one
/// that still says it is a sheet of a window no longer on screen.
@MainActor final class OrphanedSheetSweeperTests: XCTestCase {
    func testASheetWhoseWindowIsGoneIsTakenAway() async throws {
        let parent = StandIn(), orphan = StandIn(sheetOf: parent)
        let sweeper = OrphanedSheetSweeper(windows: { [orphan] }, delay: .milliseconds(10))
        sweeper.start()
        defer { sweeper.stop() }
        orphan.orderFront(nil)
        XCTAssertTrue(OrphanedSheetSweeper.isOrphaned(orphan))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: NSWindow())
        try await wait { !orphan.isVisible }
    }

    func testAttachedNestedSheetsAndSheetsOfMinimizedWindowsStay() async throws {
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Color.clear.frame(width: 300, height: 200).sheet(isPresented: .constant(true)) {
            Text("Outer").frame(width: 260, height: 160).sheet(isPresented: .constant(true)) {
                Text("Inner").frame(width: 200, height: 100)
            }
        })
        window.orderFront(nil) // Offscreen; sheets need an ordered window.
        defer { window.close(); window.contentView = nil }
        try await wait { window.attachedSheet?.attachedSheet?.isVisible == true }
        let outer = try XCTUnwrap(window.attachedSheet), inner = try XCTUnwrap(outer.attachedSheet)
        XCTAssertTrue(outer.isSheet && inner.isSheet, "The sweep must recognise SwiftUI's sheets")
        let minimized = StandIn(), docked = StandIn(sheetOf: minimized)
        minimized.minimized = true
        docked.orderFront(nil)
        defer { docked.orderOut(nil) }
        OrphanedSheetSweeper(windows: { [outer, inner, docked] }).sweep()
        XCTAssertTrue(outer.isVisible); XCTAssertTrue(inner.isVisible); XCTAssertTrue(docked.isVisible)
        XCTAssertTrue(window.attachedSheet === outer)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < end else { XCTFail("Timed out"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class StandIn: NSWindow {
    private weak var presenter: NSWindow?
    private var presentedAsSheet = false
    var minimized = false

    convenience init(sheetOf parent: NSWindow? = nil) {
        self.init(contentRect: .init(x: -10000, y: -10000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        presenter = parent
        presentedAsSheet = parent != nil
    }

    override var isSheet: Bool { presentedAsSheet }
    override var sheetParent: NSWindow? { presenter }
    override var isMiniaturized: Bool { minimized }
}
