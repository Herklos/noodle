import AppKit
import SwiftUI
import XCTest
import NoodleSettingsUI

@MainActor final class SheetSizingTests: XCTestCase {
    func testContentStaysHiddenWhileTheSheetResizes() async throws {
        let fixture = try await sheet(Fixture(model: Model()))
        try await wait { fixture.contentHeight == 200 && self.centre(of: fixture.host) == .red }

        fixture.model.height = 320
        try await wait { self.centre(of: fixture.host) == .clear }
        XCTAssertLessThan(fixture.contentHeight, 319, "resized at once instead of animating")
        try await wait { self.centre(of: fixture.host) == .red }
        XCTAssertEqual(fixture.contentHeight, 320, accuracy: 0.5, "shown before the sheet had its size")
    }

    func testTallContentStaysOnScreen() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("No screen to fit") }
        let model = Model()
        model.height = screen.visibleFrame.height + 400
        let fixture = try await sheet(Fixture(model: model))
        try await wait { fixture.contentHeight > 0 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThanOrEqual(fixture.contentHeight, screen.visibleFrame.height)
    }

    func testScrollbarClearsTheRoundedCorners() async throws {
        let fixture = try await sheet(Form {
            ForEach(0..<100) { Text("Row \($0)") }
        }.formStyle(.grouped).frame(width: 300))
        try await wait { self.find(NSScrollView.self, in: fixture.host) != nil }
        let insets = try XCTUnwrap(find(NSScrollView.self, in: fixture.host)).scrollerInsets
        XCTAssertGreaterThanOrEqual(insets.top, 16)
        XCTAssertGreaterThanOrEqual(insets.bottom, 16)
    }

    func testContentThatFitsDoesNotBounce() async throws {
        let fixture = try await sheet(Form { Text("Row") }.formStyle(.grouped).frame(width: 300))
        try await wait { self.find(NSScrollView.self, in: fixture.host) != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try XCTUnwrap(find(NSScrollView.self, in: fixture.host)).verticalScrollElasticity, .none)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let view = view as? T { return view }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    @MainActor private struct Sheet {
        let model: Model
        let window: NSWindow
        let host: NSView
        var contentHeight: CGFloat { window.contentRect(forFrameRect: window.frame).height }
    }

    private func sheet(_ fixture: Fixture) async throws -> Sheet {
        try await sheet(fixture, model: fixture.model)
    }

    private func sheet(_ content: some View, model: Model? = nil) async throws -> Sheet {
        _ = NSApplication.shared
        let parent = window(height: 600)
        let sheet = window(height: 100)
        let host = NSHostingView(rootView: content.noodleSheetSizing())
        host.sizingOptions = []
        sheet.contentView = host
        // Exercise a real sheet offscreen without taking focus.
        parent.orderBack(nil)
        parent.beginSheet(sheet, completionHandler: nil)
        addTeardownBlock { @MainActor in parent.endSheet(sheet) }
        try await wait { sheet.sheetParent === parent }
        return Sheet(model: model ?? Model(), window: sheet, host: host)
    }

    private func window(height: CGFloat) -> NSWindow {
        let window = FixtureWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        return window
    }

    private enum Colour { case red, clear, other }

    private func centre(of host: NSView) -> Colour {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return .other }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let colour = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
            .usingColorSpace(.sRGB) else { return .other }
        if colour.redComponent > 0.9 && colour.greenComponent < 0.2 && colour.blueComponent < 0.2 { return .red }
        if colour.alphaComponent < 0.1 || abs(colour.redComponent - colour.blueComponent) < 0.1 { return .clear }
        return .other
    }

    private func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Sheet did not settle", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor private final class Model: ObservableObject {
    @Published var height: CGFloat = 200
}

private struct Fixture: View {
    @ObservedObject var model: Model

    var body: some View {
        Color(red: 1, green: 0, blue: 0).frame(width: 300, height: model.height)
    }
}

private final class FixtureWindow: NSWindow {
    // Keep the fixture offscreen, including on test runners without a display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
