import Foundation
@testable import HubLink
import XCTest

/// Signing in to a browser watched live: what travels reads across app versions, and what a person
/// typed never shows in a description that could reach a log.
final class LinkSignInTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    func testSignInRequestsReadAsSent() throws {
        let expected: [(String, LinkRequest)] = [
            (#"{"signInForm":{"conversationID":"\#(a)","attachmentID":"\#(b)"}}"#, .signInForm(conversationID: a, attachmentID: b)),
            (#"{"fillSignIn":{"_0":{"conversationID":"\#(a)","attachmentID":"\#(b)","token":"\#(c)","password":"pw"}}}"#,
             .fillSignIn(LinkSignInFill(conversationID: a, attachmentID: b, token: c, password: "pw"))),
            (#"{"fillSignIn":{"_0":{"conversationID":"\#(a)","attachmentID":"\#(b)","token":"\#(c)","oneTimeCode":"123456","submit":true}}}"#,
             .fillSignIn(LinkSignInFill(conversationID: a, attachmentID: b, token: c, oneTimeCode: "123456", submit: true))),
        ]
        for (json, request) in expected {
            XCTAssertEqual(try LinkProtocol.decoder.decode(LinkRequest.self, from: Data(json.utf8)), request, json)
            XCTAssertEqual(try LinkProtocol.decode(try LinkProtocol.encode(request)).get(), request, json)
        }
    }

    /// A field of a kind a later Browser finds is left out, rather than the whole form being unreadable.
    func testAFormReadsAcrossVersions() throws {
        let json = #"{"signInForm":{"_0":{"token":"\#(c)","host":"login.example.test","pageHost":"login.example.test","secure":true,"crossOrigin":false,"#
            + #""fields":[{"kind":"username","label":"Email"},{"kind":"passkey"},{"kind":"one-time-code","length":6}]}}}"#
        let response = try LinkProtocol.decodeResponse(Data(json.utf8))
        let form = LinkSignInForm(token: c, host: "login.example.test", pageHost: "login.example.test", secure: true, crossOrigin: false,
                                  fields: [LinkSignInField(kind: .username, label: "Email"), LinkSignInField(kind: .oneTimeCode, length: 6)])
        XCTAssertEqual(response, .signInForm(form))
        XCTAssertEqual(try LinkProtocol.decodeResponse(LinkProtocol.encode(.signInForm(form))), .signInForm(form))
    }

    /// A Hub from before sign-in says nothing of it, so devices offer none.
    func testOnlyAHubThatSaysSoSignsIn() throws {
        let old = try LinkProtocol.decoder.decode(LinkStatus.self, from: Data(#"{"hubName":"Mac mini"}"#.utf8))
        XCTAssertFalse(old.signsInToBrowsers)
        let current = LinkStatus(hubName: "Mac mini", userName: "Ada", planName: "", harnesses: [], endpoints: [], signsInToBrowsers: true)
        XCTAssertTrue(try LinkProtocol.decoder.decode(LinkStatus.self, from: LinkProtocol.encoder.encode(current)).signsInToBrowsers)
    }

    func testWhatAPersonTypedNeverShowsInADescription() {
        let fill = LinkSignInFill(conversationID: a, attachmentID: b, token: c, username: "ada@example.com", password: "correct horse",
                                  newPassword: "battery staple", oneTimeCode: "482913")
        let request = LinkRequest.fillSignIn(fill)
        var dumped = ""
        dump(request, to: &dumped)
        for text in [String(describing: request), String(reflecting: request), "\(fill)", dumped] {
            for secret in ["ada@example.com", "correct horse", "battery staple", "482913"] { XCTAssertFalse(text.contains(secret), text) }
        }
    }
}
