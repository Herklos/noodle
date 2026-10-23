import HubLink
import SwiftUI

extension HubChats {
    /// Whether the Hub finds and fills the sign-in fields of a browser watched live.
    var signsInToBrowsers: Bool { pairing.status?.signsInToBrowsers == true }

    /// The sign-in fields of the page a browser card shows, while this phone watches it live.
    func signInForm(_ attachment: LinkAttachment, in conversation: some HubConversation) async throws -> LinkSignInForm {
        guard case .signInForm(let form) = try await pairing.request(.signInForm(conversationID: conversation.conversationID,
                                                                                  attachmentID: attachment.id)) else {
            throw LinkError("The Hub did not answer. Try again.")
        }
        return form
    }

    func fillSignIn(_ fill: LinkSignInFill) async throws {
        _ = try await pairing.request(.fillSignIn(fill))
    }
}

/// Native fields for a page's sign-in form, so the Passwords key and one-time codes from Messages appear
/// above the keyboard. The site they go to is shown first, with a warning when it is not the page's own
/// or not secure.
struct BrowserSignInSheet: View {
    let form: LinkSignInForm
    let send: (LinkSignInEntry) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entry = LinkSignInEntry()
    @State private var working = false
    @State private var problem: String?
    @FocusState private var focused: LinkSignInField.Kind?

    var body: some View {
        NavigationStack {
            Form {
                Section { LinkSignInSite(form) }
                Section {
                    if form.has(.username, .email) {
                        TextField(form.has(.email) && !form.has(.username) ? "Email" : "Username", text: $entry.username)
                            .textContentType(.username)
                            .keyboardType(form.has(.email) ? .emailAddress : .default)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused, equals: .username)
                    }
                    if form.has(.password) {
                        SecureField("Password", text: $entry.password).textContentType(.password).focused($focused, equals: .password)
                    }
                    if form.has(.newPassword) {
                        SecureField("New Password", text: $entry.newPassword).textContentType(.newPassword)
                            .focused($focused, equals: .newPassword)
                    }
                    if form.has(.oneTimeCode) {
                        TextField("Code", text: $entry.oneTimeCode).textContentType(.oneTimeCode).keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focused, equals: .oneTimeCode)
                    }
                    Toggle("Submit", isOn: $entry.submit)
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .privacySensitive()
            // Closing it while the values are on their way would lose what the Hub says about them.
            .interactiveDismissDisabled(working)
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fill", action: fill).disabled(working || entry.isEmpty)
                }
            }
            .onAppear { focused = form.firstField }
            // What was typed goes once; nothing of it stays behind.
            .onDisappear { entry = LinkSignInEntry() }
        }
    }

    private func fill() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await send(entry)
                entry = LinkSignInEntry()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
