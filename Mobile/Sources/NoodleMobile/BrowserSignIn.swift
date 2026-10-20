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

/// What a person types or picks from their passwords to sign in to a page they watch live. Only the
/// fields the page has are offered, and only what was entered goes to it.
struct BrowserSignInEntry: Equatable {
    var username = ""
    var password = ""
    var newPassword = ""
    var oneTimeCode = ""
    var submit = false

    func fill(_ form: LinkSignInForm, conversationID: UUID, attachmentID: UUID) -> LinkSignInFill {
        let kinds = Set(form.fields.map(\.kind))
        func value(_ text: String, _ wanted: LinkSignInField.Kind...) -> String? {
            !text.isEmpty && !kinds.isDisjoint(with: wanted) ? text : nil
        }
        return LinkSignInFill(conversationID: conversationID, attachmentID: attachmentID, token: form.token,
                              username: value(username, .username, .email), password: value(password, .password),
                              newPassword: value(newPassword, .newPassword),
                              oneTimeCode: value(oneTimeCode.trimmingCharacters(in: .whitespaces), .oneTimeCode), submit: submit)
    }

    var isEmpty: Bool { username.isEmpty && password.isEmpty && newPassword.isEmpty && oneTimeCode.isEmpty }
}

/// Native fields for a page's sign-in form, so the Passwords key and one-time codes from Messages appear
/// above the keyboard. The site they go to is shown first, with a warning when it is not the page's own
/// or not secure.
struct BrowserSignInSheet: View {
    let form: LinkSignInForm
    let send: (BrowserSignInEntry) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entry = BrowserSignInEntry()
    @State private var working = false
    @State private var problem: String?
    @FocusState private var focused: LinkSignInField.Kind?

    private func has(_ kinds: LinkSignInField.Kind...) -> Bool { form.fields.contains { kinds.contains($0.kind) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if form.host.isEmpty {
                        Label("This form doesn't say which site it's from.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Label(form.host, systemImage: form.secure ? "lock.fill" : "lock.open.fill")
                    }
                    if !form.secure {
                        Label("This page isn't secure.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if form.crossOrigin {
                        Label(form.pageHost.isEmpty ? "This form is from another site." : "This form is from another site than \(form.pageHost).",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    if has(.username, .email) {
                        TextField(has(.email) && !has(.username) ? "Email" : "Username", text: $entry.username)
                            .textContentType(.username)
                            .keyboardType(has(.email) ? .emailAddress : .default)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused, equals: .username)
                    }
                    if has(.password) {
                        SecureField("Password", text: $entry.password).textContentType(.password).focused($focused, equals: .password)
                    }
                    if has(.newPassword) {
                        SecureField("New Password", text: $entry.newPassword).textContentType(.newPassword)
                            .focused($focused, equals: .newPassword)
                    }
                    if has(.oneTimeCode) {
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
            .onAppear { focused = form.fields.first.map { $0.kind == .email ? .username : $0.kind } }
            // What was typed goes once; nothing of it stays behind.
            .onDisappear { entry = BrowserSignInEntry() }
        }
    }

    private func fill() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await send(entry)
                entry = BrowserSignInEntry()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
