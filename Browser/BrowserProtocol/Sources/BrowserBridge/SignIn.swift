import Foundation

/// A sign-in field on the page a person watches live, as `signInForm` finds it.
public struct BrowserSignInField: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case username, email, password
        case newPassword = "new-password"
        case oneTimeCode = "one-time-code"
    }
    public var kind: Kind
    /// What the page calls the field, at most 60 characters. The page wrote it, so it is never
    /// the only thing that says what goes in.
    public var label: String?
    /// How many boxes a code is split across, one character in each.
    public var length: Int?
    public init(kind: Kind, label: String? = nil, length: Int? = nil) { self.kind = kind; self.label = label; self.length = length }
}

/// The sign-in fields of one form on the page a person watches live: in the main page or one of its
/// frames, whichever holds the focused field or else the likeliest form. `token` names it to `signInFill`.
public struct BrowserSignInForm: Codable, Equatable, Sendable {
    /// What a Noodle Browser lists among its features when it finds and fills sign-in fields.
    public static let feature = "sign-in-v1"
    public var token: UUID
    /// The site whose fields they are, from the frame's own origin; empty for a frame with no site.
    public var host: String
    /// The site of the page the person sees, which differs from `host` for a form in a frame of another site.
    public var pageHost: String
    /// Whether the fields' frame was loaded over HTTPS.
    public var secure: Bool
    /// Whether the fields are in a frame of another site than the page.
    public var crossOrigin: Bool
    public var fields: [BrowserSignInField]
    public init(token: UUID, host: String, pageHost: String, secure: Bool, crossOrigin: Bool, fields: [BrowserSignInField]) {
        self.token = token; self.host = host; self.pageHost = pageHost; self.secure = secure; self.crossOrigin = crossOrigin
        self.fields = fields
    }
}

/// What a person typed or picked to sign in, sent once to fill the form `token` names. It is never
/// logged or kept: descriptions and mirrors of it leave the values out.
public struct BrowserSignInValues: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let maximumLength = 4096
    public var token: UUID
    /// Goes into username and email fields.
    public var username: String?
    public var password: String?
    public var newPassword: String?
    public var oneTimeCode: String?
    /// Submits the form once filled, as its button or Return would.
    public var submit: Bool
    public init(token: UUID, username: String? = nil, password: String? = nil, newPassword: String? = nil, oneTimeCode: String? = nil,
                submit: Bool = false) {
        self.token = token; self.username = username; self.password = password; self.newPassword = newPassword
        self.oneTimeCode = oneTimeCode; self.submit = submit
    }
    public var description: String { "BrowserSignInValues(token: \(token), values: redacted, submit: \(submit))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["token": token, "submit": submit], displayStyle: .struct) }

    public func validate() throws {
        let values = [username, password, newPassword, oneTimeCode].compactMap { $0 }
        guard !values.isEmpty else { throw BrowserError("Enter something to sign in with.") }
        for value in values where value.utf8.count > Self.maximumLength || value.utf8.contains(0) {
            throw BrowserError("A sign-in value is too long or contains a null character.")
        }
    }
}
