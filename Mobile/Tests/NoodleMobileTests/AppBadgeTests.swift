import Foundation
import HubLink
@testable import NoodleMobile
import Testing

@Suite struct AppBadgeTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    /// A Hub's folder as the phone keeps it, with its topic; joined unless it is being left.
    private func hub(in hubs: URL, joined: Bool = true) throws -> (directory: URL, topic: String) {
        let directory = hubs.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if joined { try Data("{}".utf8).write(to: directory.appendingPathComponent("hub.json")) }
        return (directory, PushTopic.topic(for: directory))
    }

    /// Word of replies counts each conversation once, on every Hub joined. A Hub being left, or one
    /// the phone no longer has, counts nothing.
    @Test func wordOfRepliesCountsEachConversationOnce() throws {
        let hubs = folder()
        let studio = try hub(in: hubs), home = try hub(in: hubs), leaving = try hub(in: hubs, joined: false)
        let first = UUID(), second = UUID()
        #expect(AppBadge.count(hubs: hubs) == 0)

        #expect(AppBadge.arrived(NotificationRoute(topic: studio.topic, conversation: first), hubs: hubs) == 1)
        #expect(AppBadge.arrived(NotificationRoute(topic: studio.topic, conversation: first), hubs: hubs) == 1)
        #expect(AppBadge.arrived(NotificationRoute(topic: home.topic, conversation: second), hubs: hubs) == 2)
        #expect(AppBadge.arrived(NotificationRoute(topic: leaving.topic, conversation: UUID()), hubs: hubs) == 2)
        #expect(AppBadge.arrived(NotificationRoute(topic: "unknown", conversation: UUID()), hubs: hubs) == nil)
        #expect(AppBadge.unread(in: studio.directory) == [first])
        #expect(AppBadge.unread(in: home.directory) == [second])
    }

    /// Taken back by the Hub, as once read on any device, the conversation leaves the count. Word
    /// taken back about one not counted, or under another Hub's topic, changes nothing.
    @Test func wordTakenBackLeavesTheCount() throws {
        let hubs = folder()
        let studio = try hub(in: hubs), home = try hub(in: hubs)
        let read = UUID(), waiting = UUID(), elsewhere = UUID()
        AppBadge.setUnread([read, waiting], in: studio.directory)
        AppBadge.setUnread([elsewhere], in: home.directory)

        let withdrawal = PushWithdrawal(topic: studio.topic, recordName: LinkPush.recordName(topic: studio.topic, conversation: read))
        #expect(AppBadge.withdrawn(withdrawal, hubs: hubs))
        #expect(AppBadge.unread(in: studio.directory) == [waiting])
        #expect(AppBadge.count(hubs: hubs) == 2)

        #expect(!AppBadge.withdrawn(withdrawal, hubs: hubs))
        #expect(!AppBadge.withdrawn(PushWithdrawal(topic: home.topic, recordName: withdrawal.recordName), hubs: hubs))
        #expect(!AppBadge.withdrawn(PushWithdrawal(topic: "unknown", recordName: withdrawal.recordName), hubs: hubs))
        #expect(AppBadge.unread(in: home.directory) == [elsewhere])
    }

    /// A withdrawal is about the conversation whose record name it carries, under its own topic.
    @Test func aWithdrawalMatchesItsConversation() {
        let conversation = UUID()
        let withdrawal = PushWithdrawal(topic: "abc", recordName: LinkPush.recordName(topic: "abc", conversation: conversation))
        #expect(withdrawal.matches(NotificationRoute(topic: "abc", conversation: conversation)))
        #expect(!withdrawal.matches(NotificationRoute(topic: "abc", conversation: UUID())))
        #expect(!withdrawal.matches(NotificationRoute(topic: "xyz", conversation: conversation)))
    }

    /// Read on this phone, a conversation leaves the count; a damaged file counts nothing.
    @Test func readHereLeavesTheCount() throws {
        let hubs = folder()
        let studio = try hub(in: hubs)
        let read = UUID(), waiting = UUID()
        AppBadge.setUnread([read, waiting], in: studio.directory)
        AppBadge.read(read, in: studio.directory)
        #expect(AppBadge.unread(in: studio.directory) == [waiting])

        try Data("not json".utf8).write(to: studio.directory.appendingPathComponent(AppBadge.fileName))
        #expect(AppBadge.count(hubs: hubs) == 0)
    }
}
