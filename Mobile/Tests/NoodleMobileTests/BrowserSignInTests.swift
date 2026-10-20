import Foundation
import HubLink
@testable import NoodleMobile
import Testing

/// Signing in to a browser watched live sends only what the page asks for and was entered, and
/// submits only when asked.
struct BrowserSignInTests {
    private let conversation = UUID(), attachment = UUID()

    private func form(_ kinds: LinkSignInField.Kind...) -> LinkSignInForm {
        LinkSignInForm(token: UUID(), host: "login.example.com", pageHost: "login.example.com", secure: true, crossOrigin: false,
                       fields: kinds.map { LinkSignInField(kind: $0) })
    }

    @Test func onlyWhatThePageAsksForAndWasEnteredIsSent() {
        let page = form(.email, .password)
        var entry = BrowserSignInEntry()
        entry.username = "ada@example.com"
        entry.password = "correct horse"
        entry.oneTimeCode = "482913"
        let fill = entry.fill(page, conversationID: conversation, attachmentID: attachment)
        #expect(fill.token == page.token)
        #expect(fill.conversationID == conversation && fill.attachmentID == attachment)
        #expect(fill.username == "ada@example.com")
        #expect(fill.password == "correct horse")
        #expect(fill.oneTimeCode == nil, "a code went to a page without a code field")
        #expect(fill.newPassword == nil)
    }

    @Test func aCodeIsSentWithoutSpacesAndNothingEmptyIsSent() {
        var entry = BrowserSignInEntry()
        entry.oneTimeCode = " 482913 "
        let fill = entry.fill(form(.username, .oneTimeCode), conversationID: conversation, attachmentID: attachment)
        #expect(fill.oneTimeCode == "482913")
        #expect(fill.username == nil)
    }

    @Test func theFormIsSubmittedOnlyWhenAsked() {
        var entry = BrowserSignInEntry()
        entry.password = "correct horse"
        #expect(!entry.fill(form(.password), conversationID: conversation, attachmentID: attachment).submit)
        entry.submit = true
        #expect(entry.fill(form(.password), conversationID: conversation, attachmentID: attachment).submit)
    }
}
