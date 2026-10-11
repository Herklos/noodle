import AppKit
import SwiftUI
import XCTest
import NoodleCore
import NoodleSettingsUI
@testable import NoodleRuntime
@testable import NoodleRuntimeSettings

@MainActor final class HarnessSelectionSheetTests: XCTestCase {
    func testDoneTurnsOnAHarnessThatWasOff() async throws {
        let fixture = try RuntimeCoordinatorFixture()
        defer { fixture.cleanUp() }
        fixture.runtime.setHarness(.fx, on: false)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 600, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Noodle harness selection test"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SelectionSheetFixture(runtime: fixture.runtime))
        window.orderFront(nil)
        defer {
            for sheet in window.sheets { window.endSheet(sheet) }
            window.close()
            window.contentView = nil
        }

        var sheet: NSWindow?
        for _ in 0..<100 where sheet == nil {
            try await Task.sleep(for: .milliseconds(20))
            sheet = window.sheets.first
        }
        let sheetWindow = try XCTUnwrap(sheet, "Choose Harnesses did not appear")
        let switches = descendants(try XCTUnwrap(sheetWindow.contentView)).compactMap { $0 as? NSSwitch }
        XCTAssertEqual(switches.count, HarnessProvider.allCases.count)
        let fx = switches[try XCTUnwrap(HarnessProvider.allCases.firstIndex(of: .fx))]
        XCTAssertEqual(fx.state, .off)
        fx.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        let done = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheetWindow.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        XCTAssertTrue(sheetWindow.performKeyEquivalent(with: done))
        for _ in 0..<100 where !window.sheets.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertTrue(window.sheets.isEmpty)
        XCTAssertTrue(fixture.runtime.harnesses.isOn(.fx))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

private struct SelectionSheetFixture: View {
    let runtime: AgentRuntimeCoordinator
    @State private var presented = true
    var body: some View {
        Text("Harness selection fixture")
            .frame(width: 600, height: 600)
            .sheet(isPresented: $presented) {
                HarnessSelectionView(runtime: runtime).noodleSheetSizing()
            }
    }
}
