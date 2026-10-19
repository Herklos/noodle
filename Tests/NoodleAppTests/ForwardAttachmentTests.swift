import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class ForwardAttachmentTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    /// A file sent in Ada's conversation.
    private func sentFile(_ f: StoreFixture) throws -> ConversationAttachment {
        let url = f.runtime.root.appendingPathComponent("report.txt")
        try Data("Quarterly numbers".utf8).write(to: url)
        f.store.importAttachment(from: url, into: f.directA.id)
        let file = try XCTUnwrap(f.store.pendingAttachments(for: f.directA.id).last)
        f.store.sendDraft(to: f.directA.id)
        return file
    }

    func testForwardingSendsOneMessageWithACopyOfTheFileAndTheComment() throws {
        let f = try fixture(), file = try sentFile(f)
        // What is being written to Grace stays as it was.
        let staged = f.runtime.root.appendingPathComponent("staged.txt")
        try Data("Staged".utf8).write(to: staged)
        f.store.importAttachment(from: staged, into: f.directB.id)
        f.store.setDraft("Half a thought", for: f.directB.id)
        let pending = f.store.pendingAttachments(for: f.directB.id)

        let message = try f.store.forward(file, to: f.directB.id, comment: "  For the review \n")

        XCTAssertEqual(message.author, .user)
        XCTAssertEqual(message.body, "For the review")
        XCTAssertEqual(try f.repository.loadMessages(conversationID: f.directB.id).map(\.id), [message.id])
        XCTAssertEqual(f.store.messages(for: f.directB).map(\.id), [message.id])
        let copy = try XCTUnwrap(f.store.attachments(for: message).first)
        XCTAssertEqual(message.attachments, [copy.id])
        XCTAssertNotEqual(copy.id, file.id)
        XCTAssertEqual(copy.conversationID, f.directB.id)
        XCTAssertEqual(copy.originalFilename, "report.txt")
        XCTAssertEqual(copy.mediaType, file.mediaType)
        XCTAssertEqual(try Data(contentsOf: f.store.attachmentFileURL(copy)), Data("Quarterly numbers".utf8))
        // Grace hears of it; Ada's conversation and file are untouched.
        XCTAssertEqual(f.runtime.factory.processes.filter { $0.configuration.id == f.b.id }.flatMap(\.notifications), [false])
        XCTAssertEqual(try f.repository.loadMessages(conversationID: f.directA.id).count, 1)
        XCTAssertEqual(try Data(contentsOf: f.store.attachmentFileURL(file)), Data("Quarterly numbers".utf8))
        XCTAssertEqual(f.store.draft(for: f.directB.id), "Half a thought")
        XCTAssertEqual(f.store.pendingAttachments(for: f.directB.id), pending)
    }

    func testForwardingWithoutACommentSaysWhatWasSent() throws {
        let f = try fixture(), file = try sentFile(f), group = try f.group()
        let message = try f.store.forward(file, to: group.id, comment: " \n ")
        XCTAssertEqual(message.body, "Sent 1 attachment")
        XCTAssertEqual(f.store.attachments(for: message).map(\.originalFilename), ["report.txt"])
    }

    func testOnlyFilesCanBeForwardedAndOnlyToAConversationThatExists() throws {
        let f = try fixture(), file = try sentFile(f)
        XCTAssertTrue(AttachmentForwarding.canForward(file))
        XCTAssertThrowsError(try f.store.forward(file, to: UUID(), comment: "Hi"))
        let link = try f.repository.importLinkAttachment(try XCTUnwrap(URL(string: "https://example.com")), into: f.directA.id)
        XCTAssertFalse(AttachmentForwarding.canForward(link))
        XCTAssertThrowsError(try f.store.forward(link, to: f.directB.id, comment: "Hi"))
        let audio = f.runtime.root.appendingPathComponent("recording.caf")
        try Data([0, 1, 2, 3]).write(to: audio)
        let voice = VoiceMessage(transcript: "A note", duration: 2, waveform: [0.5], localeIdentifier: "en-GB")
        XCTAssertFalse(AttachmentForwarding.canForward(try f.repository.importAttachment(
            from: audio, into: f.directA.id, mediaType: "audio/x-caf", voice: voice)))
        XCTAssertTrue(f.store.messages(for: f.directB).isEmpty)
    }

    func testTheSheetListsOtherBotsAndGroupsThatCanTakeMessagesAndSearchesTheirNames() throws {
        let f = try fixture(), group = try f.group(name: "Project")
        let ids = { (search: String) in AttachmentForwarding.targets(in: f.store, from: f.directA.id, search: search).map(\.id) }
        XCTAssertEqual(Set(ids("")), [f.directB.id, group.id])
        XCTAssertEqual(ids(" proj "), [group.id])
        XCTAssertEqual(ids("grace"), [f.directB.id])
        XCTAssertEqual(ids("Nobody"), [])
        // An archived bot takes no messages; the group still has Ada.
        XCTAssertTrue(f.store.setArchived(true, agentID: f.b.id))
        XCTAssertEqual(ids(""), [group.id])
    }
}
