import NoodleCore
import SwiftUI

/// Forward…: a file of one conversation sent on to another bot or group.
enum AttachmentForwarding {
    /// Files only: a recording, a comment on another file and a link stay where they were made.
    static func canForward(_ attachment: ConversationAttachment) -> Bool {
        attachment.url == nil && attachment.voice == nil && attachment.annotation == nil
    }

    /// The bots and groups a file can go to, found and ordered as the conversation picker finds them: by
    /// name, newest first. The file's own conversation and those that take no messages now are left out.
    @MainActor static func targets(in store: NoodleStore, from conversationID: UUID, search: String) -> [AgentPickerItem] {
        let open = Set(store.conversations.filter {
            $0.id != conversationID && store.composerUnavailableReason(for: $0) == nil
        }.map(\.id))
        return AgentPickerItem.visible(AgentPickerItem.items(in: store, floating: []).filter { open.contains($0.id) },
                                       filter: search)
    }
}

extension EnvironmentValues {
    /// Opens Forward… for a file, presented by the conversation rather than the message it is in.
    @Entry var forwardAttachment: (@MainActor (ConversationAttachment) -> Void)?
}

/// Picks the bot or group a file goes to, with an optional comment, and sends it there.
struct ForwardAttachmentSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let attachment: ConversationAttachment
    @State private var search = ""
    @State private var chosenID: UUID?
    @State private var comment = ""
    @State private var failure: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let targets = AttachmentForwarding.targets(in: store, from: attachment.conversationID, search: search)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Forward").font(.headline)
                Spacer()
                Button("Send", action: send)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .disabled(chosenID == nil)
                    .keyboardShortcut(.defaultAction)
            }
            Label(attachment.originalFilename, systemImage: "doc")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(targets) { row($0) }
                }
            }
            .frame(height: 240)
            .overlay {
                if targets.isEmpty { Text("No Conversations").foregroundStyle(.secondary) }
            }
            TextField("Comment", text: $comment)
                .textFieldStyle(.roundedBorder)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { searchFocused = true }
        // A search that hides the chosen one leaves nothing chosen, so Send never goes somewhere unseen.
        .onChange(of: targets.map(\.id)) { _, shown in
            if let chosenID, !shown.contains(chosenID) { self.chosenID = nil }
        }
    }

    private func row(_ item: AgentPickerItem) -> some View {
        let conversation = store.conversations.first { $0.id == item.id }
        let chosen = chosenID == item.id
        return Button { chosenID = item.id } label: {
            HStack(spacing: 10) {
                ConversationAvatar(participants: conversation.map { store.shownParticipants(for: $0) } ?? [],
                                   isGroup: conversation?.kind == .group, size: 28)
                Text(item.title).lineLimit(1)
                Spacer()
                if chosen {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(chosen ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func send() {
        guard let chosenID else { return }
        // A file only its Hub has comes down first, to go up again with the forwarded copy.
        guard store.hubKeeping(attachment) == nil else {
            Task {
                guard await store.downloadedFile(attachment) != nil else { return }
                send()
            }
            return
        }
        do {
            try store.forward(attachment, to: chosenID, comment: comment)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
