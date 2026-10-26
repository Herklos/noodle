import NoodleCore

/// How a harness login is named where it is a choice, such as a bot's Profile.
public enum HarnessLoginName {
    /// The app's own login for the harness: the account it is signed in to, tagged Default,
    /// so it reads as that account rather than as a login of its own.
    public static func defaultLogin(account: String?, status: HarnessAuthenticationStatus?) -> String {
        switch status {
        case .authenticated: account.map { "\($0) · Default" } ?? "Default"
        case .unauthenticated: "Default · not signed in"
        default: "Default"
        }
    }
}
