import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class ColumnHeaderInteractionTests: HiddenViewTests {
    private func header(_ conversation: BotConversation, fixture: StoreFixture,
                        close: @escaping () -> Void = {}) -> NSView {
        host(ColumnHeader(conversation: conversation, isFocused: false, kickRequest: .constant(nil),
            select: {}, reorder: .init(targeted: { _ in }, drop: { _ in }), close: close)
            .environment(fixture.store))
    }

    func testPencilEditsItsOwnBotWithoutSelectingAnotherColumn() async throws {
        let f = try fixture()
        f.store.selectedConversationID = f.directB.id
        let view = header(f.directA, fixture: f)
        _ = try await control("Close Column", in: view)
        XCTAssertTrue(hasControl("Edit Bot", in: view), "The column needs a direct edit button")
        XCTAssertFalse(hasControl("Conversation Info", in: view), "Editing must not open an actions menu")
        guard hasControl("Edit Bot", in: view) else { return }
        press(try await control("Edit Bot", in: view))
        XCTAssertEqual(f.store.agentBeingEdited?.id, f.a.id)
        XCTAssertEqual(f.store.selectedConversationID, f.directB.id)
    }

    func testPencilEditsItsOwnGroupAndCloseStillClosesOnlyTheColumn() async throws {
        let f = try fixture(), group = try f.group()
        f.store.selectedConversationID = f.directA.id
        var closed = false
        let view = header(group, fixture: f, close: { closed = true })
        let close = try await control("Close Column", in: view)
        XCTAssertTrue(hasControl("Group Info", in: view), "The column needs a direct group editor button")
        XCTAssertFalse(hasControl("Call", in: view))
        XCTAssertFalse(hasControl("Shared", in: view))
        guard hasControl("Group Info", in: view) else { return }
        press(try await control("Group Info", in: view))
        XCTAssertEqual(f.store.groupBeingEdited?.id, group.id)
        XCTAssertEqual(f.store.selectedConversationID, f.directA.id)
        press(close)
        XCTAssertTrue(closed)
    }

    func testButtonsFollowListOrderWithCloseLast() async throws {
        let f = try fixture()
        let link = URL(string: "noodlebrowser://\(UUID())?tab=\(UUID())")!
        let attachment = try f.repository.importLinkAttachment(link, into: f.directA.id)
        _ = try f.repository.sendUserMessage(conversationID: f.directA.id, body: "Shared browser", attachmentIDs: [attachment.id])
        f.store.refreshTranscripts()
        try f.runtime.start(f.a).transition(.failed, failure: .usageLimit)
        let view = header(f.directA, fixture: f)
        _ = try await control("Shared", in: view)
        let names = ["Edit Bot", "Kick", "Call", "Shared", "Close Column"]
        XCTAssertTrue(hasControl("Edit Bot", in: view), "Edit comes before pause, call and shared items, as in list mode")
        guard hasControl("Edit Bot", in: view) else { return }
        var previousX = -CGFloat.infinity
        for name in names {
            let node = try await control(name, in: view)
            let frame = try XCTUnwrap((node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, name)
            XCTAssertGreaterThan(frame.midX, previousX, "\(name) is out of order")
            previousX = frame.midX
        }
    }
}
