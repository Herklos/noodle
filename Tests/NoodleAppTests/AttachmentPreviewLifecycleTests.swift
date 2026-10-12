import AppKit
import QuickLookUI
import SwiftUI
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class AttachmentPreviewLifecycleTests: XCTestCase {
    private func source(_ name: String = "Fixture.txt") -> ConversationAttachment {
        .init(conversationID: UUID(), originalFilename: name, storedFilename: name, mediaType: "text/plain", byteCount: 7)
    }
    private func controller() -> AttachmentPreviewController {
        _ = NSApplication.shared
        let controller = AttachmentPreviewController()
        addTeardownBlock { @MainActor in controller.close() }; return controller
    }
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        addTeardownBlock { @MainActor in window.close() }; return window
    }
    private func snapshot() -> NSImage {
        NSImage(size: NSSize(width: 60, height: 40), flipped: false) { rect in NSColor.blue.setFill(); rect.fill(); return true }
    }

    func testClosingWhileCaptureIsPendingDiscardsLateImage() async throws {
        let c = controller(), gate = RoutingGate<Void>()
        var presentations = 0
        c.prepareAnnotationContent(source: source(), isCurrent: { true }, load: { _ in
            try await gate.value(); return .init(image: self.snapshot(), frame: .zero)
        }, present: { _ in presentations += 1 })
        let operation = try XCTUnwrap(c.operation)
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(c.busy)
        c.close(); gate.resolve(.success(())); await operation.value
        XCTAssertFalse(c.busy); XCTAssertNil(c.pending); XCTAssertNil(c.pendingImage)
        XCTAssertEqual(presentations, 0)
        XCTAssertFalse(c.hasPendingAnnotation)
    }

    func testNewPreparationOwnsBusyStateAndIgnoresOldSuccessOrFailure() async throws {
        for fails in [false, true] {
            let c = controller(), old = RoutingGate<Void>(), next = RoutingGate<Void>(), newer = source("New.txt")
            var errors = 0, presentations = 0
            c.reportError = { _ in errors += 1 }
            c.prepareAnnotationContent(source: source(), isCurrent: { true }, load: { _ in
                try await old.value(); return .init(quote: "Old selection")
            }, present: { _ in XCTFail("Old capture presented") })
            let previous = try XCTUnwrap(c.operation)
            await fulfillment(of: [old.entered], timeout: 2)
            c.prepareAnnotationContent(source: newer, isCurrent: { true }, load: { _ in
                try await next.value(); return .init(quote: "New selection")
            }, present: { _ in presentations += 1 })
            let current = try XCTUnwrap(c.operation)
            await fulfillment(of: [next.entered], timeout: 2)
            old.resolve(fails ? .failure(CocoaError(.fileReadNoSuchFile)) : .success(())); await previous.value
            XCTAssertTrue(c.busy); XCTAssertNil(c.pending); XCTAssertEqual(errors, 0)
            next.resolve(.success(())); await current.value
            XCTAssertEqual(c.pending?.source.id, newer.id)
            XCTAssertEqual(c.pending?.quote, "New selection")
            XCTAssertFalse(c.busy); XCTAssertEqual(presentations, 1)
        }
    }

    func testLostFocusDropsCaptureAndDoesNotPresentItsError() async throws {
        for fails in [false, true] {
            let c = controller(), gate = RoutingGate<Void>()
            var current = true, errors = 0
            c.reportError = { _ in errors += 1 }
            c.prepareAnnotationContent(source: source(), isCurrent: { current }, load: { _ in
                try await gate.value(); return .init(quote: "Elsewhere")
            }, present: { _ in XCTFail("Inactive preview presented a comment") })
            let operation = try XCTUnwrap(c.operation)
            await fulfillment(of: [gate.entered], timeout: 2)
            current = false
            gate.resolve(fails ? .failure(CocoaError(.fileReadUnknown)) : .success(())); await operation.value
            XCTAssertFalse(c.busy); XCTAssertNil(c.pending); XCTAssertEqual(errors, 0)
        }
    }

    func testCurrentCaptureFailureClearsBusyAndCanBeRetried() async throws {
        let c = controller(), attachment = source()
        var errors = 0
        c.reportError = { _ in errors += 1 }
        c.prepareAnnotationContent(source: attachment, isCurrent: { true }, load: { _ in throw CocoaError(.fileReadUnknown) }, present: { _ in XCTFail() })
        await c.operation?.value
        XCTAssertFalse(c.busy); XCTAssertNil(c.pending); XCTAssertEqual(errors, 1)
        c.prepareAnnotationContent(source: attachment, isCurrent: { true }, load: { _ in .init(quote: "Retry") }, present: { _ in })
        await c.operation?.value
        XCTAssertEqual(c.pending?.quote, "Retry")
    }

    func testMovingOwnerToAnotherWindowCancelsPendingPreparation() async throws {
        let c = controller(), first = window(), second = window(), gate = RoutingGate<Void>()
        c.attach(to: first)
        c.prepareAnnotationContent(source: source(), isCurrent: { true }, load: { _ in
            try await gate.value(); return .init(quote: "Old window")
        }, present: { _ in XCTFail("Old window result escaped") })
        let operation = try XCTUnwrap(c.operation)
        await fulfillment(of: [gate.entered], timeout: 2)
        c.attach(to: second); gate.resolve(.success(())); await operation.value
        XCTAssertTrue(c.resolveHostWindow() === second)
        XCTAssertNil(c.pending); XCTAssertFalse(c.busy)
        c.detach(); XCTAssertNil(c.resolveHostWindow())
    }

    func testMissingAttachmentReportsFailureWithoutAcquiringQuickLook() {
        let c = controller(), host = window()
        c.attach(to: host)
        var errors = 0
        c.reportError = { _ in errors += 1 }
        c.show(source(), url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { _, _, _ in XCTFail() }
        XCTAssertEqual(errors, 1)
        XCTAssertNil(c.currentURL)
        XCTAssertEqual(c.numberOfPreviewItems(in: nil), 0)
    }

    func testOldRegionCanvasCannotAlterANewerAnnotation() async throws {
        let c = controller(), host = window(), next = source("New selection.txt")
        c.annotateConversation(in: host, source: source(), quote: nil, snapshot: snapshot()) { _, _, _ in XCTFail() }
        let oldCanvas = try XCTUnwrap(c.conversationCanvas)
        c.close()
        c.prepareAnnotationContent(source: next, isCurrent: { true }, load: { _ in .init(quote: "New selection") }, present: { _ in })
        await c.operation?.value
        oldCanvas.onRegion?(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(c.pending?.source.id, next.id)
        XCTAssertNil(c.pending?.region)
        XCTAssertEqual(c.pending?.quote, "New selection")
    }

    func testFailedSaveRetainsCommentAndImageForRetryAndSavesOnlyOnce() throws {
        let c = controller(), host = window(), attachment = source()
        var fails = true, errors = 0, saved: [AttachmentAnnotation] = [], bytes: Data?
        c.reportError = { _ in errors += 1 }
        c.annotateConversation(in: host, source: attachment, quote: nil, snapshot: snapshot()) { annotation, content, source in
            XCTAssertEqual(source.id, attachment.id)
            if fails { throw CocoaError(.fileWriteNoPermission) }
            saved.append(annotation); bytes = content
        }
        c.pending?.region = .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let input = NSTextView(); input.string = "Keep this feedback"; c.commentInput = input
        c.saveComment()
        XCTAssertEqual(errors, 1); XCTAssertEqual(c.commentInput?.string, "Keep this feedback")
        XCTAssertNotNil(c.pendingImage); XCTAssertNotNil(c.pending); XCTAssertTrue(saved.isEmpty)
        fails = false; c.saveComment(); c.saveComment()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.comment, "Keep this feedback")
        XCTAssertTrue(bytes?.starts(with: [137, 80, 78, 71]) == true)
        XCTAssertNil(c.pending); XCTAssertFalse(c.hasPendingAnnotation)
    }

    func testOldOwnerReleaseCannotClearNewQuickLookBindings() throws {
        let first = controller(), next = controller(), panel = try XCTUnwrap(QLPreviewPanel.shared())
        first.configurePreviewPanel(panel); next.configurePreviewPanel(panel)
        first.releasePreviewPanel(panel)
        XCTAssertTrue(panel.dataSource as? AttachmentPreviewController === next)
        XCTAssertTrue(panel.delegate as? AttachmentPreviewController === next)
        next.releasePreviewPanel(panel)
        XCTAssertNil(panel.dataSource); XCTAssertNil(panel.delegate)
    }

    func testMessageFilesPreviewTogetherStartingAtTheOneOpened() {
        let first = source("One.png"), voice = ConversationAttachment(conversationID: UUID(), originalFilename: "Voice.m4a",
            storedFilename: "Voice.m4a", mediaType: "audio/mp4", byteCount: 7,
            voice: VoiceMessage(transcript: nil, duration: 1, waveform: [], localeIdentifier: nil))
        let link = ConversationAttachment(conversationID: UUID(), originalFilename: "Site.webloc", storedFilename: "Site.webloc",
            mediaType: "application/x-webloc", byteCount: 7, url: URL(string: "https://example.com"))
        let second = source("Two.pdf")
        let gallery = ConversationAttachment.previewGallery(opening: second, among: [first, voice, link, second])
        XCTAssertEqual(gallery.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(gallery.index, 1)
        let alone = ConversationAttachment.previewGallery(opening: link, among: [first, link, second])
        XCTAssertEqual(alone.items.map(\.id), [link.id]); XCTAssertEqual(alone.index, 0)
    }

    func testStagedFilesAreEachPreviewItemAndKeepTheirSource() {
        let c = controller(), first = source("One.txt"), second = source("Two.txt")
        let url = { (name: String) in URL(fileURLWithPath: "/tmp/\(name)") }
        c.stage([(first, url("One.txt")), (second, url("Two.txt"))], at: 1)
        XCTAssertEqual(c.numberOfPreviewItems(in: nil), 2)
        XCTAssertEqual(c.previewPanel(nil, previewItemAt: 0).previewItemTitle, "One.txt")
        XCTAssertEqual(c.previewPanel(nil, previewItemAt: 1).previewItemURL, url("Two.txt"))
        XCTAssertEqual(c.currentURL, url("Two.txt"))
        XCTAssertEqual(c.attachment(at: 0)?.id, first.id)
        // Reopening from the same message keeps the loaded items.
        let kept = c.previewPanel(nil, previewItemAt: 0)
        c.stage([(first, url("One.txt")), (second, url("Two.txt"))], at: 0)
        XCTAssertTrue(c.previewPanel(nil, previewItemAt: 0) === kept)
        XCTAssertEqual(c.currentURL, url("One.txt"))
    }

    func testWebLinksPreviewOnlyWhenEnabledAndOnlyForWebSchemes() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/a?b=1#c"))
        XCTAssertEqual(WebLinkPreview.previewed(page, enabled: true), page)
        XCTAssertNil(WebLinkPreview.previewed(page, enabled: false))
        for other in ["mailto:someone@example.com", "file:///tmp/a.html", "noodlet://00000000-0000-0000-0000-000000000001", "https:///"] {
            XCTAssertNil(WebLinkPreview.previewed(try XCTUnwrap(URL(string: other)), enabled: true), other)
        }
    }

    func testModifierClickOpensWebLinksInTheBrowserEvenWhenPreviewIsOn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WebLinkPreviewCommandClick-\(UUID())"))
        XCTAssertTrue(WebLinkPreview.opensInPreview(in: defaults, modifiers: []))
        XCTAssertTrue(WebLinkPreview.opensInPreview(in: defaults, modifiers: [.capsLock, .function]))
        // Control-click is a right-click on macOS, so it never counts.
        XCTAssertTrue(WebLinkPreview.opensInPreview(in: defaults, modifiers: [.control]))
        for modifiers: NSEvent.ModifierFlags in [.command, .option, .shift, [.command, .shift]] {
            XCTAssertFalse(WebLinkPreview.opensInPreview(in: defaults, modifiers: modifiers), "\(modifiers)")
            XCTAssertTrue(QuickLookBypass.isHeld(modifiers), "\(modifiers)")
        }
        XCTAssertFalse(QuickLookBypass.isHeld([]))
        defaults.set(false, forKey: WebLinkPreview.defaultsKey)
        XCTAssertFalse(WebLinkPreview.opensInPreview(in: defaults, modifiers: []))
    }

    func testWebLinkPreviewsItsBookmarkWithALinkSourceToAnnotate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let page = try XCTUnwrap(URL(string: "https://example.com/page"))
        let bookmark = try WebLinkPreview.bookmark(for: page, in: directory)
        XCTAssertEqual(bookmark.pathExtension, "webloc")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: bookmark), format: nil) as? [String: String]
        XCTAssertEqual(plist?["URL"], page.absoluteString)
        XCTAssertEqual(try WebLinkPreview.bookmark(for: page, in: directory), bookmark)
        XCTAssertNotEqual(try WebLinkPreview.bookmark(for: try XCTUnwrap(URL(string: "https://example.com/other")), in: directory), bookmark)

        let c = controller()
        c.stage([(source("One.txt"), URL(fileURLWithPath: "/tmp/One.txt"))], at: 0)
        let link = try WebLinkPreview.source(for: page, conversationID: UUID()).source
        c.stageLink(bookmark, title: "example.com", source: link)
        XCTAssertEqual(c.numberOfPreviewItems(in: nil), 1)
        XCTAssertEqual(c.previewPanel(nil, previewItemAt: 0).previewItemTitle, "example.com")
        XCTAssertEqual(c.currentURL, bookmark)
        XCTAssertEqual(c.attachment(at: 0), link)
        XCTAssertEqual(c.attachment(at: 0)?.url, page)
    }

    /// A web page that submits a form or reloads makes Quick Look's web display run
    /// a modal alert. If the preview closes meanwhile, answering it crashed Noodle.
    func testWebPreviewNavigationNeverRunsAModalAlert() throws {
        _ = NSApplication.shared
        QuickLookWebNavigation.install()
        let web = Bundle(path: "/System/Library/Frameworks/QuickLookUI.framework/Versions/A/PlugIns/Web2.qldisplay")
        guard let web, web.load() else { throw XCTSkip("This macOS has no Quick Look web display.") }
        // QuickLookWebNavigation patches these private names; it needs updating if they change.
        let display = try XCTUnwrap(NSClassFromString("QLWeb2DisplayBundle") as? NSObject.Type,
            "Quick Look's web display class was renamed")
        XCTAssertTrue(display.instancesRespond(to: NSSelectorFromString("_warnAboutNoNavigation")),
            "Quick Look's web display no longer has the navigation alert")
        // The display only alerts inside a visible preview; stand in for one.
        let name = "QLWeb2DisplayBundleAllowingAlerts"
        let fixture: AnyClass = NSClassFromString(name) ?? {
            let subclass: AnyClass = objc_allocateClassPair(display, name, 0)!
            let allows: @convention(block) (AnyObject) -> Bool = { _ in true }
            class_addMethod(subclass, NSSelectorFromString("allowsAlerts"), imp_implementationWithBlock(allows), "B@:")
            let preview: @convention(block) (AnyObject) -> AnyObject = { _ in WebPreviewFixture() }
            class_addMethod(subclass, NSSelectorFromString("preview"), imp_implementationWithBlock(preview), "@@:")
            objc_registerClassPair(subclass)
            return subclass
        }()
        var alerted = false
        let watch = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow != nil else { return }
                alerted = true; NSApp.abortModal()
            }
        }
        RunLoop.main.add(watch, forMode: .common)
        defer { watch.invalidate() }
        let preview = (fixture as! NSObject.Type).init()
        // A display that never showed a preview asserts when it is released.
        _ = Unmanaged.passRetained(preview)
        preview.perform(NSSelectorFromString("_warnAboutNoNavigation"))
        XCTAssertFalse(alerted)
    }

    func testNativeCloseAndRepeatedCleanupEndTheSessionOnce() {
        let host = window(); var ended = 0
        let session = PreviewWindowSession(window: host) { ended += 1 }
        host.close(); session.close(); session.close()
        XCTAssertEqual(ended, 1)
    }
    func testSwiftUIScopeCancelsCaptureWhenConversationChanges() async throws {
        _ = NSApplication.shared
        var mounted: AttachmentPreviewController?
        let host = window()
        func content(_ id: UUID) -> PreviewNavigationHost {
            PreviewNavigationHost(conversationID: id, record: { mounted = $0 })
        }
        let hosting = NSHostingView(rootView: content(UUID()))
        host.contentView = hosting; hosting.layoutSubtreeIfNeeded()
        for _ in 0..<50 where mounted == nil { try await Task.sleep(for: .milliseconds(5)) }
        let c = try XCTUnwrap(mounted), gate = RoutingGate<Void>()
        defer { c.close(); host.contentView = nil }
        c.prepareAnnotationContent(source: source(), isCurrent: { true }, load: { _ in
            try await gate.value(); return .init(quote: "Previous conversation")
        }, present: { _ in XCTFail("Navigation retained the old selection") })
        let operation = try XCTUnwrap(c.operation)
        await fulfillment(of: [gate.entered], timeout: 2)
        hosting.rootView = content(UUID()); hosting.layoutSubtreeIfNeeded()
        await fulfillment(of: [gate.cancelled], timeout: 2)
        XCTAssertTrue(mounted === c, "Navigation must keep the window's mounted owner")
        gate.resolve(.success(())); await operation.value
        XCTAssertNil(c.pending); XCTAssertFalse(c.busy)
    }

}


private struct PreviewNavigationHost: View {
    let conversationID: UUID
    let record: (AttachmentPreviewController) -> Void
    var body: some View {
        AttachmentPreviewScope(conversationID: conversationID) { controller in
            PreviewOwnerRecorder(controller: controller, record: record)
        }
    }
}
private final class WebPreviewFixture: NSObject {
    @objc let url = NSURL(string: "https://example.com/next")
}
private struct PreviewOwnerRecorder: View {
    init(controller: AttachmentPreviewController, record: (AttachmentPreviewController) -> Void) { record(controller) }
    var body: some View { Text("Fixture conversation") }
}
