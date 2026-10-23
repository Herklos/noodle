import Foundation
import NoodleCore
import XCTest
@testable import Noodle

/// What the Shortcuts actions ask of the store: sending with files, opening a conversation and calling a bot.
@MainActor final class ShortcutActionTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        f.store.makeCallPeer = { VoiceCallPeerFake() }
        f.store.conversationWindows.openMainWindow = {}
        return f
    }

    private func wait(_ what: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<500 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate(), what)
    }

    func testSendingWithFilesCopiesThemIntoTheConversationAndLeavesWhatIsBeingWritten() throws {
        let f = try fixture()
        let report = f.runtime.root.appendingPathComponent("report.txt")
        try Data("Quarterly numbers".utf8).write(to: report)
        let staged = f.runtime.root.appendingPathComponent("staged.txt")
        try Data("Staged".utf8).write(to: staged)
        f.store.importAttachment(from: staged, into: f.directB.id)
        f.store.setDraft("Half a thought", for: f.directB.id)
        let pending = f.store.pendingAttachments(for: f.directB.id)

        let message = try f.store.sendCommand("Have a look", files: [
            .file(report),
            .data(Data("PNG".utf8), originalFilename: "Shot.png", mediaType: "image/png"),
        ], to: f.directB.id)

        XCTAssertEqual(message.body, "Have a look")
        XCTAssertEqual(try f.repository.loadMessages(conversationID: f.directB.id).map(\.id), [message.id])
        let sent = f.store.attachments(for: message)
        XCTAssertEqual(message.attachments, sent.map(\.id))
        XCTAssertEqual(sent.map(\.originalFilename), ["report.txt", "Shot.png"])
        XCTAssertEqual(sent.map(\.conversationID), [f.directB.id, f.directB.id])
        XCTAssertEqual(sent.last?.mediaType, "image/png")
        XCTAssertEqual(try Data(contentsOf: f.store.attachmentFileURL(sent[0])), Data("Quarterly numbers".utf8))
        // A copy: the original stays where it was.
        XCTAssertNotEqual(f.store.attachmentFileURL(sent[0]).standardizedFileURL, report.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
        XCTAssertEqual(f.runtime.factory.processes.filter { $0.configuration.id == f.b.id }.flatMap(\.notifications), [false])
        XCTAssertEqual(f.store.draft(for: f.directB.id), "Half a thought")
        XCTAssertEqual(f.store.pendingAttachments(for: f.directB.id), pending)
    }

    func testFilesSentWithoutWordsSayWhatWasSent() throws {
        let f = try fixture(), group = try f.group()
        let message = try f.store.sendCommand(" \n ", files: [
            .data(Data("a".utf8), originalFilename: "a.txt", mediaType: "text/plain"),
            .data(Data("b".utf8), originalFilename: "b.txt", mediaType: "text/plain"),
        ], to: group.id)
        XCTAssertEqual(message.body, "Sent 2 attachments")
        XCTAssertEqual(f.store.attachments(for: message).map(\.originalFilename), ["a.txt", "b.txt"])
        XCTAssertThrowsError(try f.store.sendCommand("Hi", files: [.data(Data("a".utf8), originalFilename: "a.txt",
                                                                         mediaType: "text/plain")], to: UUID()))
    }

    func testOpeningAConversationSelectsItAndOneThatIsGoneIsAnError() throws {
        let f = try fixture(), group = try f.group()
        f.store.selectedConversationID = f.directA.id
        try f.store.openConversation(group.id)
        XCTAssertEqual(f.store.selectedConversationID, group.id)
        XCTAssertThrowsError(try f.store.openConversation(UUID()))
        XCTAssertEqual(f.store.selectedConversationID, group.id)
    }

    func testCallingABotStartsTheCallAndOpensItsChat() async throws {
        let f = try fixture()
        f.store.selectedConversationID = f.directB.id
        try f.store.callFromShortcut(f.directA.id, media: VoiceCallMediaFake())
        XCTAssertEqual(f.store.selectedConversationID, f.directA.id)
        try await wait("the call with Ada started") { f.store.voiceCalls.call != nil }
        let call = try XCTUnwrap(f.store.voiceCalls.call)
        XCTAssertEqual(call.conversationID, f.directA.id)
        // Calling the bot already on the call keeps that call.
        try f.store.callFromShortcut(f.directA.id, media: VoiceCallMediaFake())
        XCTAssertEqual(f.store.voiceCalls.call?.id, call.id)
        f.store.voiceCalls.hangUp()
    }

    func testCallingWhatCannotTakeCallsOnlyOpensItsChat() throws {
        let f = try fixture(), group = try f.group()
        f.store.selectedConversationID = f.directA.id
        try f.store.callFromShortcut(group.id, media: VoiceCallMediaFake())
        XCTAssertEqual(f.store.selectedConversationID, group.id)
        XCTAssertNil(f.store.voiceCalls.call)
        XCTAssertThrowsError(try f.store.callFromShortcut(UUID(), media: VoiceCallMediaFake()))
    }
}
