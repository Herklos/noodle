import AppKit
import NoodleCore
import SwiftUI
import WidgetKit
import XCTest
@testable import NoodleWidgets

@MainActor
final class WidgetHitTestingTests: XCTestCase {
    func testLauncherAvatarDoesNotRejectMouseHits() throws {
        let host = host(BotLauncherContents(bots: [try bot()], family: .systemMedium), size: NSSize(width: 308, height: 128))
        // Places in the avatar, including its centre and edges. The first
        // launcher cell is one quarter of the widget's width.
        for point in [NSPoint(x: 38.5, y: 56), NSPoint(x: 25, y: 56), NSPoint(x: 52, y: 56)] {
            assertAcceptsMouseHit(host, at: point)
        }
    }

    func testStatusAvatarAndRowPaddingDoNotRejectMouseHits() throws {
        let host = host(BotStatusContents(bots: [try bot()], family: .systemMedium), size: NSSize(width: 308, height: 308))
        assertAcceptsMouseHit(host, at: NSPoint(x: 15, y: 15))
        assertAcceptsMouseHit(host, at: NSPoint(x: 290, y: 15))
    }

    func testLauncherSymbolAvatarDoesNotRejectMouseHits() throws {
        var bot = try bot()
        bot.image = nil
        bot.symbol = "sparkles"
        let host = host(BotLauncherContents(bots: [bot], family: .systemMedium), size: NSSize(width: 308, height: 128))
        assertAcceptsMouseHit(host, at: NSPoint(x: 38.5, y: 56))
    }

    private func bot() throws -> WidgetBot {
        let image = NSImage(size: NSSize(width: 80, height: 80), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return WidgetBot(id: UUID(), conversationID: UUID(), name: "Ava",
                         image: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), status: "Ready")
    }

    private func host<V: View>(_ view: V, size: NSSize) -> NSView {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        addTeardownBlock { @MainActor in window.close(); window.contentView = nil }
        return hosting
    }

    private func assertAcceptsMouseHit(_ host: NSView, at point: NSPoint,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let point = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
        let target = host.hitTest(point)
        XCTAssertNotNil(target, "The link must cover this part of its label", file: file, line: line)
        // The default macOS Link style installs a native text control over the
        // whole label. Its view claims the image, but its cell rejects that hit.
        // WidgetKit then falls back to opening the app without the link's URL.
        if let control = target as? NSControl, let cell = control.cell, let window = host.window {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: host.convert(point, to: nil),
                                           modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            XCTAssertFalse(cell.hitTest(for: event, in: control.bounds, of: control).isEmpty,
                           "A native text control intercepts and rejects this link hit", file: file, line: line)
        }
    }
}
