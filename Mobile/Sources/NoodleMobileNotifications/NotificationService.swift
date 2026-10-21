import Foundation
import Intents
import UserNotifications

/// Turns a Hub's word of unread replies into a notification that names the bot and shows what it
/// said, fetched from the Hub itself. Nothing but the topic and the conversation passes through Apple.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    /// Delivered once: with the reply, or as it came when time runs out.
    private var pending: (content: UNMutableNotificationContent, deliver: (UNNotificationContent) -> Void)?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return contentHandler(request.content) }
        guard let route = PushTopic.route(userInfo: request.content.userInfo), let hubs = AppGroup.hubs else { return contentHandler(content) }
        // One stack per conversation in Notification Center.
        content.threadIdentifier = route.conversation.uuidString
        // The icon counts the conversation too, with those already waiting on every Hub.
        if let count = AppBadge.arrived(route, hubs: hubs) { content.badge = NSNumber(value: count) }
        lock.withLock { pending = (content, contentHandler) }
        Task { @MainActor in
            let reply = await ReplyNotification.content(for: route, hubs: hubs)
            // As a message from the bot, with its picture, which also has the share sheet suggest the conversation.
            var intent: INSendMessageIntent?
            if let reply, let sender = reply.sender {
                let message = ConversationSuggestions.intent(from: sender, in: reply.target, saying: reply.text)
                await ConversationSuggestions.donate(message, .incoming, of: reply.target)
                intent = message
            }
            self.finish(with: reply, from: intent)
        }
    }

    /// Out of time, the notification shows as it came: "New reply".
    override func serviceExtensionTimeWillExpire() { finish(with: nil, from: nil) }

    private func finish(with reply: ReplyNotification.Content?, from intent: INSendMessageIntent?) {
        lock.withLock {
            guard let pending else { return }
            self.pending = nil
            if let reply {
                pending.content.title = reply.title
                pending.content.body = reply.body
            }
            // iOS names the bot and the group itself.
            if let reply, let intent, let message = pending.content.mutableCopy() as? UNMutableNotificationContent {
                message.body = reply.text
                if let updated = try? message.updating(from: intent) { return pending.deliver(updated) }
            }
            pending.deliver(pending.content)
        }
    }
}
