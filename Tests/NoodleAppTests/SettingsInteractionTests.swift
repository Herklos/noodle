import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// Uses the native accessibility/event interfaces of this test process only.
/// No external accessibility permission or real harness account is needed.
@MainActor final class SettingsInteractionTests: HiddenViewTests {
    func testEditorSaveButtonPersistsEditedName() async throws {
        let f = try fixture(), editor = host(EditBotSheet(agent: f.a).environment(f.store))
        let field = try await nameField(in: editor, name: f.a.displayName)
        edit(field, text: "Renamed through UI")
        press(try await control("Save", in: editor))
        try await wait { f.store.agents.first { $0.id == f.a.id }?.displayName == "Renamed through UI" }
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.displayName, "Renamed through UI")
    }

    func testEditorFailedSaveKeepsChangesAndRetryPersistsWithoutDuplicate() async throws {
        let f = try fixture(), process = try f.runtime.start(f.a)
        let editor = host(EditBotSheet(agent: f.a).environment(f.store))
        let field = try await nameField(in: editor, name: f.a.displayName)
        edit(field, text: "Retained edit")
        let configuration = f.repository.storage(for: f.a.id).configuration
        let original = try Data(contentsOf: configuration)
        try FileManager.default.removeItem(at: configuration)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        press(try await control("Save", in: editor))
        try await wait { f.store.errorMessage != nil }
        XCTAssertEqual(field.stringValue, "Retained edit"); XCTAssertEqual(process.stops, 0)
        XCTAssertEqual(f.store.agents.first { $0.id == f.a.id }?.displayName, f.a.displayName)
        try FileManager.default.removeItem(at: configuration); try original.write(to: configuration)
        press(try await control("Save", in: editor))
        try await wait { f.store.agents.first { $0.id == f.a.id }?.displayName == "Retained edit" }
        XCTAssertEqual(try f.repository.loadAgents().count, 2)
    }

    func testEditorRejectsBlankNameAndCancelDoesNotPersistDraft() async throws {
        let f = try fixture(), editor = host(EditBotSheet(agent: f.a).environment(f.store))
        let field = try await nameField(in: editor, name: f.a.displayName)
        edit(field, text: "  ")
        let save = try await control("Save", in: editor)
        try await wait { !self.enabled(save) }
        edit(field, text: "Cancelled edit")
        press(try await control("Cancel", in: editor))
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.displayName, f.a.displayName)
    }

    /// A failed save in Edit Bot is shown over the sheet and stays until OK (issue #21).
    func testAnErrorIsShownOverTheOpenSheetUntilOK() async throws {
        let f = try fixture()
        let window = try XCTUnwrap(host(Color.clear.frame(width: 300, height: 200)).window)
        window.orderFront(nil) // Offscreen; sheets need an ordered window.
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        try await wait { window.attachedSheet == sheet }
        let presenter = StoreErrorAlert(store: f.store, window: { window })
        f.store.errorMessage = "One of the selected browsers is unavailable."
        try await wait { sheet.attachedSheet != nil }
        let alert = try XCTUnwrap(sheet.attachedSheet)
        XCTAssertTrue(labels(of: alert).contains("One of the selected browsers is unavailable."))
        // Losing and regaining attention must not dismiss it.
        window.resignKey(); sheet.resignKey(); window.makeKey()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(sheet.attachedSheet); XCTAssertNotNil(f.store.errorMessage)
        let ok = try XCTUnwrap(views(in: alert.contentView).compactMap { $0 as? NSButton }.first { $0.title == "OK" })
        ok.performClick(nil)
        try await wait { sheet.attachedSheet == nil && f.store.errorMessage == nil }
        window.endSheet(sheet)
        withExtendedLifetime(presenter) {}
    }

    /// An error that comes with a link, such as an older bot's upgrade steps, offers it beside OK (issue #195).
    func testAnErrorWithALinkOpensItFromTheAlert() async throws {
        let f = try fixture()
        let window = try XCTUnwrap(host(Color.clear.frame(width: 300, height: 200)).window)
        window.orderFront(nil)
        final class Opened { var urls: [URL] = [] }
        let opened = Opened(), url = AgentStorageError.upgradeStepsURL
        let presenter = StoreErrorAlert(store: f.store, window: { window }, open: { opened.urls.append($0) })
        f.store.errorLink = .init(message: "Grace can't start.", title: "Upgrade Steps", url: url)
        f.store.errorMessage = "Grace can't start."
        try await wait { window.attachedSheet != nil }
        let alert = try XCTUnwrap(window.attachedSheet)
        let buttons = views(in: alert.contentView).compactMap { $0 as? NSButton }
        XCTAssertNotNil(buttons.first { $0.title == "OK" })
        try XCTUnwrap(buttons.first { $0.title == "Upgrade Steps" }).performClick(nil)
        try await wait { window.attachedSheet == nil && f.store.errorMessage == nil }
        XCTAssertEqual(opened.urls, [url])
        XCTAssertNil(f.store.errorLink)
        withExtendedLifetime(presenter) {}
    }

    private func views(in root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { views(in: $0) }
    }
    private func labels(of window: NSWindow) -> [String] {
        views(in: window.contentView).compactMap { ($0 as? NSTextField)?.stringValue }
    }
}
