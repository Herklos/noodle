import AppKit
import SwiftUI
import XCTest
import NoodleSettingsUI

@MainActor final class SettingsTabViewTests: XCTestCase {
    func testNewTabStaysHiddenUntilTheWindowHasResized() async throws {
        let selection = Selection()
        let host = NSHostingView(rootView: Fixture(selection: selection))
        host.sizingOptions = []
        let window = FixtureWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        window.orderBack(nil)

        try await wait { self.centre(of: host) == .red }
        selection.tab = 1
        try await wait { self.centre(of: host) == .clear }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(centre(of: host), .clear, "shown before the resize finished")
        try await wait { self.centre(of: host) == .blue }
    }

    /// SwiftUI keeps a closed Settings window and its content. Content that still follows the
    /// app's data piles up observations for as long as the app runs, so a closed window holds none.
    func testAClosedWindowStopsFollowingTheAppsData() async throws {
        let model = Model()
        let host = NSHostingView(rootView: LiveFixture(model: model))
        host.sizingOptions = []
        let window = FixtureWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        window.orderBack(nil)
        try await wait { self.centre(of: host) == .red }
        let frame = window.frame

        window.close()
        try await Task.sleep(for: .milliseconds(100))
        let evaluations = model.evaluations
        for value in 1...5 {
            model.value = value
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.evaluations, evaluations, "a closed window still updates its content")

        window.orderBack(nil)
        try await wait { self.centre(of: host) == .red }
        XCTAssertEqual(window.frame, frame, "reopening keeps the window's size")
    }

    private enum Colour { case red, blue, clear, other }

    private func centre(of host: NSView) -> Colour {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return .other }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let colour = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh * 2 / 3)?
            .usingColorSpace(.sRGB) else { return .other }
        if colour.redComponent > 0.9 && colour.greenComponent < 0.2 && colour.blueComponent < 0.2 { return .red }
        if colour.blueComponent > 0.9 && colour.redComponent < 0.2 && colour.greenComponent < 0.2 { return .blue }
        if colour.alphaComponent < 0.1 || abs(colour.redComponent - colour.blueComponent) < 0.1 { return .clear }
        return .other
    }

    private func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Settings tab did not settle", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor private final class Selection: ObservableObject {
    @Published var tab = 0
}

private struct Fixture: View {
    @ObservedObject var selection: Selection

    var body: some View {
        SettingsTabView(selection: $selection.tab) {
            Color(red: 1, green: 0, blue: 0).frame(width: 300, height: 260).tabItem { Text("Red") }.tag(0)
            Color(red: 0, green: 0, blue: 1).frame(width: 300, height: 260).tabItem { Text("Blue") }.tag(1)
        }
    }
}

@MainActor @Observable private final class Model {
    var value = 0
    @ObservationIgnored var evaluations = 0
}

private struct LiveFixture: View {
    let model: Model

    var body: some View {
        SettingsTabView(selection: .constant(0)) {
            LiveRow(model: model).frame(width: 300, height: 260).tabItem { Text("Red") }.tag(0)
        }
    }
}

private struct LiveRow: View {
    let model: Model

    var body: some View {
        model.evaluations += 1
        return Color(red: 1, green: 0, blue: 0).overlay(Text("\(model.value)"))
    }
}

private final class FixtureWindow: NSWindow {
    // Keep the fixture offscreen, including on test runners without a display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
