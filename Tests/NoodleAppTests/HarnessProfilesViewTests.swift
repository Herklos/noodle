import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntimeSettings

@MainActor final class HarnessProfilesViewTests: HiddenViewTests {
    func testProfileRowsOfferSignInWhileTheirStatusIsUnknown() async throws {
        let f = try fixture()
        _ = try f.store.harnessProfiles.create(provider: .codex, named: "Work")
        // No executable: the status check cannot run, and sign-in must stay reachable.
        let sheet = host(HarnessProfilesView(store: f.store, installation: HarnessInstallation(provider: .codex, executablePath: nil))
            .environment(f.store))
        _ = try await control("Codex Profiles", in: sheet)
        _ = try await control("Work", in: sheet)
        for name in ["Sign In…", "Add Profile…", "Done"] {
            let button = try await control(name, in: sheet)
            XCTAssertTrue(enabled(button), name)
        }
    }

    /// The sign-in check only reads the saved login, so a bot on the profile that the vendor
    /// refused is what tells that the profile needs signing in again.
    func testAProfileWhoseBotWasRefusedItsLoginSaysSignInIsRequired() async throws {
        let f = try fixture()
        let profile = try f.store.harnessProfiles.create(provider: .codex, named: "Work")
        let other = try f.store.harnessProfiles.create(provider: .codex, named: "Home")
        try f.repository.updateAgentHarnessProfile(f.a, profile: profile.id)
        try f.repository.updateAgentHarnessProfile(f.b, profile: other.id)
        let bot = try f.runtime.start(f.a)
        try f.runtime.start(f.b).transition(.failed, failure: .usageLimit)
        let sheet = host(HarnessProfilesView(store: f.store, installation: HarnessInstallation(provider: .codex, executablePath: nil))
            .environment(f.store))
        _ = try await control("Work", in: sheet)
        XCTAssertFalse(hasControl("Sign-in required", in: sheet))
        bot.transition(.failed, failure: .authenticationRequired)
        _ = try await control("Sign-in required", in: sheet)
        bot.transition(.ready)
        try await wait { !self.hasControl("Sign-in required", in: sheet) }
    }
}
