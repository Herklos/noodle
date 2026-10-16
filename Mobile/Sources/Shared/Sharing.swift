import Foundation
import HubLink
import Intents
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A bot or group Noodle's share sheet offers. The app keeps the list in each Hub's folder, so the
/// share extension shows it at once, without asking the Hub.
struct ShareTarget: Codable, Equatable, Identifiable, Sendable {
    /// Its Hub's folder and its conversation there; iOS keeps it to suggest the conversation when sharing.
    struct Key: Codable, Hashable, Sendable {
        let hub: String
        let conversation: UUID

        init(hub: String, conversation: UUID) {
            self.hub = hub
            self.conversation = conversation
        }

        init?(identifier: String) {
            guard let slash = identifier.lastIndex(of: "/"),
                  let conversation = UUID(uuidString: String(identifier[identifier.index(after: slash)...])) else { return nil }
            self.init(hub: String(identifier[..<slash]), conversation: conversation)
        }

        var identifier: String { "\(hub)/\(conversation.uuidString)" }
    }

    let key: Key
    let name: String
    let hubName: String
    let isGroup: Bool
    /// The bot, or the group's bots its picture shows.
    let faces: [BotFace]
    var pinned = false
    /// When its latest message was sent, or it was made.
    var recency = Date.distantPast

    var id: String { key.identifier }

    init(key: Key, name: String, hubName: String, isGroup: Bool, faces: [BotFace], pinned: Bool = false,
         recency: Date = .distantPast) {
        self.key = key
        self.name = name
        self.hubName = hubName
        self.isGroup = isGroup
        self.faces = faces
        self.pinned = pinned
        self.recency = recency
    }

    init(bot: LinkBot, hub folder: URL, hubName: String) {
        self.init(key: Key(hub: folder.lastPathComponent, conversation: bot.conversationID), name: bot.draft.name,
                  hubName: hubName, isGroup: false, faces: [BotFace(bot)], recency: bot.createdAt)
    }

    /// Archived bots leave a group's picture, unless every one of them is.
    init(group: LinkGroup, members: [LinkBot], hub folder: URL, hubName: String) {
        let active = members.filter { $0.archivedAt == nil }
        self.init(key: Key(hub: folder.lastPathComponent, conversation: group.id), name: group.draft.name, hubName: hubName,
                  isGroup: true, faces: (active.isEmpty ? members : active).map(BotFace.init), recency: group.createdAt)
    }
}

/// Where each Hub's folder keeps what the share sheet offers from it.
@MainActor enum ShareTargets {
    static func url(in folder: URL) -> URL { folder.appendingPathComponent("share-targets.json") }

    static func save(_ targets: [ShareTarget], in folder: URL) {
        try? JSONEncoder().encode(targets).write(to: url(in: folder), options: .atomic)
    }

    static func load(in folder: URL) -> [ShareTarget] {
        (try? JSONDecoder().decode([ShareTarget].self, from: Data(contentsOf: url(in: folder)))) ?? []
    }

    /// Every joined Hub's, pinned first, then newest conversation first, as the list orders them.
    static func all(in hubs: URL) -> [ShareTarget] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: hubs, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { !HubPairing.isLeaving($0) }.flatMap(load(in:))
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.pinned != rhs.element.pinned { return lhs.element.pinned }
                if lhs.element.recency != rhs.element.recency { return lhs.element.recency > rhs.element.recency }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// A file picked on the phone, waiting to be sent. Its ID becomes the attachment's.
struct OutgoingFile: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
    let filename: String
    let mediaType: String
    var voice: LinkVoice?
}

/// A message of words and files, as every Noodle sends one.
enum OutgoingMessages {
    static let voiceBody = "Voice message"

    static func make(_ body: String, files: [OutgoingFile], to conversationID: UUID) throws
        -> (message: LinkOutgoingMessage, attachments: [LinkAttachment]) {
        let attachments = try files.map { file in
            LinkAttachment(id: file.id, filename: file.filename, mediaType: file.mediaType,
                           byteCount: try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, voice: file.voice,
                           pixelSize: file.mediaType.hasPrefix("image/") ? LinkPixelSize(pictureAt: file.url) : nil)
        }
        // As on the Mac, a message of files alone says how many, and a recording alone what it is.
        let text = !body.isEmpty || files.isEmpty ? body
            : files.count == 1 && files[0].voice != nil ? voiceBody
            : "Sent \(files.count) attachment\(files.count == 1 ? "" : "s")"
        return (LinkOutgoingMessage(conversationID: conversationID, id: UUID(), body: text, attachmentIDs: attachments.map(\.id)),
                attachments)
    }
}

/// Copies picked files where they stay readable until sent.
enum PickedFiles {
    static func store(_ data: Data, named filename: String, type: UTType?) throws -> OutgoingFile {
        let url = try folder().appendingPathComponent(filename)
        try data.write(to: url)
        return OutgoingFile(url: url, filename: filename, mediaType: type?.preferredMIMEType ?? "application/octet-stream")
    }

    /// A file from the Files app, which is readable only while its access is held.
    static func copy(_ source: URL, named filename: String? = nil) throws -> OutgoingFile {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let filename = filename ?? source.lastPathComponent
        let url = try folder().appendingPathComponent(filename)
        try FileManager.default.copyItem(at: source, to: url)
        return OutgoingFile(url: url, filename: filename,
                            mediaType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
    }

    static func photo(_ item: PhotosPickerItem, number: Int) async throws -> OutgoingFile? {
        guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first
        let kind = type?.conforms(to: .movie) == true ? "Video" : "Photo"
        return try store(data, named: "\(kind) \(number).\(type?.preferredFilenameExtension ?? "jpg")", type: type)
    }

    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Outgoing", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// What another app shared: links and words become the message, everything else its files, in the order shared.
@MainActor enum SharedItems {
    struct Loaded {
        var text = ""
        var files: [OutgoingFile] = []
    }

    /// An item that cannot be read is left out.
    static func load(_ providers: [NSItemProvider]) async -> Loaded {
        var words: [String] = [], files: [OutgoingFile] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await object(URL.self, from: provider) {
                words.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = await object(String.self, from: provider) {
                words.append(text)
            } else if let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .url) }),
                      let file = await file(type, from: provider) {
                files.append(file)
            } else if let file = await picture(from: provider) {
                files.append(file)
            }
        }
        return Loaded(text: words.joined(separator: "\n"), files: files)
    }

    // Each handler is @Sendable: iOS calls them off the main thread, where one isolated to it would abort.
    private static func object<T: _ObjectiveCBridgeable & Sendable>(_: T.Type, from provider: NSItemProvider) async -> T?
        where T._ObjectiveCType: NSItemProviderReading {
        guard provider.canLoadObject(ofClass: T.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: T.self) { @Sendable object, _ in continuation.resume(returning: object) }
        }
    }

    /// Named as the app shared it, with the extension its type has.
    private static func file(_ type: UTType, from provider: NSItemProvider) async -> OutgoingFile? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { @Sendable url, _, _ in
                guard let url else { return continuation.resume(returning: nil) }
                var filename = suggested ?? url.deletingPathExtension().lastPathComponent
                if let ext = type.preferredFilenameExtension ?? (url.pathExtension.isEmpty ? nil : url.pathExtension),
                   (filename as NSString).pathExtension.lowercased() != ext.lowercased() {
                    filename += ".\(ext)"
                }
                continuation.resume(returning: try? PickedFiles.copy(url, named: filename))
            }
        }
    }

    /// Some apps share a picture only as an image object.
    private static func picture(from provider: NSItemProvider) async -> OutgoingFile? {
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        let suggested = provider.suggestedName
        let png: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { @Sendable image, _ in
                continuation.resume(returning: (image as? UIImage)?.pngData())
            }
        }
        guard let png else { return nil }
        return try? PickedFiles.store(png, named: "\(suggested ?? "Image").png", type: .png)
    }
}

/// Sends what was shared straight to the Hub, files first, as the app does.
@MainActor enum SharedSend {
    /// `sent` hears how many files the Hub has so far.
    static func send(_ body: String, files: [OutgoingFile], to target: ShareTarget, hubs: URL,
                     sent: (Int) -> Void = { _ in }) async throws {
        let folder = hubs.appendingPathComponent(target.key.hub, isDirectory: true)
        let pairing = HubPairing(directory: folder, deviceName: "")
        guard pairing.hub != nil, !HubPairing.isLeaving(folder) else { throw LinkError("This iPhone is no longer in \(target.hubName).") }
        let (message, attachments) = try OutgoingMessages.make(body, files: files, to: target.key.conversation)
        for (index, (file, attachment)) in zip(files, attachments).enumerated() {
            try await pairing.upload(file.url, as: attachment, to: target.key.conversation)
            sent(index + 1)
        }
        guard case .message = try await pairing.request(.send(message)) else { throw LinkError("The Hub sent an unexpected answer.") }
        await ConversationSuggestions.donate(ConversationSuggestions.intent(sentTo: target), .outgoing, of: target)
    }
}

/// A bot's picture, or a group's.
struct ConversationAvatar: View {
    let target: ShareTarget
    let size: CGFloat

    var body: some View {
        if target.isGroup {
            GroupAvatar(faces: target.faces, size: size)
        } else {
            AgentAvatar(face: target.faces.first ?? BotFace(LinkBotDraft(name: target.name, provider: ""), id: UUID()), size: size)
        }
    }
}

/// Tells iOS of the conversations written in, as message apps do, so the share sheet suggests the
/// latest ones and a reply's notification shows the bot's picture.
@MainActor enum ConversationSuggestions {
    static func intent(sentTo target: ShareTarget) -> INSendMessageIntent {
        let recipients = target.isGroup ? target.faces.map { person($0, in: target) }
            : [person(target.faces.first ?? BotFace(LinkBotDraft(name: target.name, provider: ""), id: target.key.conversation), in: target)]
        return intent(target, recipients: recipients, sender: nil, content: nil)
    }

    static func intent(from face: BotFace, in target: ShareTarget, saying body: String) -> INSendMessageIntent {
        intent(target, recipients: target.isGroup ? target.faces.map { person($0, in: target) } : nil,
               sender: person(face, in: target), content: body)
    }

    private static func intent(_ target: ShareTarget, recipients: [INPerson]?, sender: INPerson?, content: String?) -> INSendMessageIntent {
        let intent = INSendMessageIntent(recipients: recipients, outgoingMessageType: .outgoingMessageText, content: content,
                                         speakableGroupName: target.isGroup ? INSpeakableString(spokenPhrase: target.name) : nil,
                                         conversationIdentifier: target.key.identifier, serviceName: nil, sender: sender,
                                         attachments: nil)
        if target.isGroup, let image = image(ConversationAvatar(target: target, size: 64)) {
            intent.setImage(image, forParameterNamed: \.speakableGroupName)
        }
        return intent
    }

    private static func person(_ face: BotFace, in target: ShareTarget) -> INPerson {
        let handle = "\(target.key.hub)/\(face.id.uuidString)"
        return INPerson(personHandle: INPersonHandle(value: handle, type: .unknown), nameComponents: nil, displayName: face.name,
                        image: image(AgentAvatar(face: face, size: 64)), contactIdentifier: nil, customIdentifier: handle)
    }

    private static func image(_ view: some View) -> INImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return renderer.uiImage?.pngData().map { INImage(imageData: $0) }
    }

    /// Kept under the conversation, so it can be forgotten with it.
    static func donate(_ intent: INSendMessageIntent, _ direction: INInteractionDirection, of target: ShareTarget) async {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = direction
        interaction.groupIdentifier = target.key.identifier
        try? await interaction.donate()
    }

    /// Conversations gone, as when a bot is deleted or its Hub left, are suggested no more.
    static func forget(_ keys: [ShareTarget.Key]) async {
        for key in keys { try? await INInteraction.delete(with: key.identifier) }
    }
}
