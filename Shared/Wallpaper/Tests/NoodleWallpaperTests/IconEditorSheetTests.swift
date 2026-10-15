import AppKit
import SwiftUI
import XCTest
@testable import NoodleWallpaper

@MainActor final class IconEditorSheetTests: XCTestCase {
    private let companionSymbols = ["desktopcomputer", "terminal", "shippingbox", "server.rack", "laptopcomputer", "globe",
        "sparkles", "bolt.fill", "brain.head.profile", "hammer.fill", "paintbrush.fill", "gearshape.2.fill"]
    private let botSymbols = ["sparkles", "bolt.fill", "brain.head.profile", "hammer.fill", "terminal.fill", "magnifyingglass",
        "shippingbox.fill", "paintbrush.fill", "checkmark.seal.fill", "ladybug.fill", "wand.and.stars", "gearshape.2.fill"]

    /// The same bound Noodle Computer's smoke test places on its icon editor.
    func testKeepsTheCompactLayoutForEveryAppsConfiguration() async throws {
        let configurations: [(String, IconAppearance, String, [String], IconImageEncoding, [Data])] = [
            ("Browser Icon", IconAppearance(symbol: "globe", colour: 2), "globe", companionSymbols, .png(maxBytes: 2 * 1024 * 1024), []),
            ("Computer Icon", IconAppearance(colour: 4), "terminal", companionSymbols, .png(maxBytes: 2 * 1024 * 1024), []),
            // A bot's colour is a seed until the user picks one: 1_000_003 % 6 == 1. Bots also offer faces.
            ("Bot Icon", IconAppearance(colour: 1_000_003), "sparkles", botSymbols, .jpeg(quality: 0.86), [Data([1])])
        ]
        for (title, icon, symbol, symbols, encoding, faces) in configurations {
            let host = NSHostingView(rootView: IconEditorSheet(title: title, icon: .constant(icon), symbol: symbol,
                symbols: symbols, encoding: encoding, faces: faces).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 570),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(300))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, 440, accuracy: 1, title)
            XCTAssertLessThan(host.bounds.height, 610, title)
            if let folder = ProcessInfo.processInfo.environment["NOODLE_ICON_EDITOR_SNAPSHOTS"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(title).png"))
            }
        }
    }

    func testDroppedImageFileBecomesTheIcon() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IconEditorSheetTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("picture.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<16 { for y in 0..<16 { bitmap.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)

        let host = NSHostingView(rootView: IconEditorSheet(title: "Bot Icon", icon: .constant(IconAppearance(colour: 1)),
            symbol: "sparkles", symbols: ["sparkles"], encoding: .png(maxBytes: 2 * 1024 * 1024)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()

        let target = try XCTUnwrap(findView(host) { !$0.registeredDraggedTypes.isEmpty }, "The icon editor accepts no drops")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))
        let drag = IconDragInfo(pasteboard: pasteboard, window: window,
            location: host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.maxY - 120), to: nil), url: source)
        XCTAssertEqual(target.draggingEntered(drag), .copy)
        XCTAssertTrue(target.performDragOperation(drag))
        // The editor keeps its draft until Done, so look for the dropped green picture in the preview badge above the colours.
        var drawn = false
        for _ in 0..<100 where !drawn {
            try await Task.sleep(for: .milliseconds(20))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            drawn = (0..<min(bitmap.pixelsHigh, 180)).contains { y in
                guard let colour = bitmap.colorAt(x: bitmap.pixelsWide / 2 - 20, y: y)?.usingColorSpace(.sRGB) else { return false }
                return colour.greenComponent > 0.8 && colour.redComponent < 0.4 && colour.blueComponent < 0.4
            }
        }
        XCTAssertTrue(drawn, "Drop did not reach the icon")
    }

    private func findView(_ view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        for child in view.subviews {
            if let found = findView(child, matching: predicate) { return found }
        }
        return predicate(view) ? view : nil
    }
}

@MainActor private final class IconDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let url: URL
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard, window: NSWindow, location: NSPoint, url: URL) {
        draggingPasteboard = pasteboard; draggingDestinationWindow = window
        draggingLocation = location; self.url = url
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        block(NSDraggingItem(pasteboardWriter: url as NSURL), 0, &stop)
    }
}

final class IconEditorDraftTests: XCTestCase {
    func testOpensOnWhatTheIconShows() {
        XCTAssertTrue(IconEditorDraft(IconAppearance(image: Data([1]))).showsPicture)
        XCTAssertFalse(IconEditorDraft(IconAppearance(symbol: "bolt.fill")).showsPicture)
    }

    func testSwitchingToTheSymbolAndBackKeepsThePicture() {
        var draft = IconEditorDraft(IconAppearance(symbol: "bolt.fill", colour: 2, image: Data([1])))
        draft.showsPicture = false
        draft.icon.iconColour = 4
        XCTAssertEqual(draft.chosen, IconAppearance(symbol: "bolt.fill", colour: 4))
        draft.showsPicture = true
        XCTAssertEqual(draft.chosen, IconAppearance(symbol: "bolt.fill", colour: 4, image: Data([1])))
    }

    func testANewPictureShowsItself() {
        var draft = IconEditorDraft(IconAppearance(colour: 1))
        draft.setPicture(Data([2]))
        XCTAssertEqual(draft.chosen, IconAppearance(colour: 1, image: Data([2])))
    }
}

final class IconEditorPlaygroundIdeaTests: XCTestCase {
    private let idea = AvatarIdea(name: "Alfred", description: "A butler")

    func testANewImageStartsFromTheBotsIdea() {
        XCTAssertEqual(IconEditorDraft(IconAppearance(colour: 1)).playgroundIdea(idea), idea)
    }

    func testEditingAPictureLeavesThePromptToThePerson() {
        XCTAssertNil(IconEditorDraft(IconAppearance(image: Data([1]))).playgroundIdea(idea))
    }
}
