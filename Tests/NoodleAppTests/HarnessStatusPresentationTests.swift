import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntime
@testable import NoodleRuntimeSettings

@MainActor final class HarnessStatusPresentationTests: HiddenViewTests {
    func testCachedUpdateErrorIsReplacedWhileRefreshingAndClearsOnSuccess() async throws {
        let f = try fixture()
        let installation = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
        let error = "Could not check the latest release. Try Check Again."
        HarnessPresentationCache.save([.codex: .init(installation: installation, authentication: .authenticated,
            version: .init(installedVersion: "0.153.4", checkError: error))], to: f.runtime.defaults)
        let checker = HarnessVersionChecker(inspect: { _ in .init(installedVersion: "0.153.4") },
            fetch: { _ in Data(#"{"tag_name":"rust-v0.154.0"}"#.utf8) })
        let setup = HarnessSetupController(providers: [:], defaults: f.runtime.defaults, versionChecker: checker)
        let row = { (refreshing: Bool) in
            HarnessInstallationRow(store: f.store, installation: installation, liveInstallation: installation,
                isRefreshing: refreshing, setup: setup, install: {}).environment(f.store)
        }
        let view = host(row(false))
        _ = try await control(error, in: view)
        _ = try await control("0.153.4", in: view)
        view.rootView = row(true)
        _ = try await control("Checking for updates…", in: view)
        XCTAssertFalse(hasControl(error, in: view))
        _ = try await control("0.153.4", in: view)
        // A check that still fails must show the error again once it finishes.
        view.rootView = row(false)
        _ = try await control(error, in: view)
        view.rootView = row(true)
        await setup.refreshVersions([installation], forceLatest: true)
        view.rootView = row(false)
        _ = try await control("Update available — 0.154.0", in: view)
        _ = try await control("Update Instructions", in: view)
        XCTAssertFalse(hasControl(error, in: view))
        XCTAssertFalse(hasControl("Checking for updates…", in: view))
    }

    func testUpdateInstructionsOpenInAPopoverWithoutGrowingTheRow() async throws {
        let f = try fixture()
        let installation = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
        HarnessPresentationCache.save([.codex: .init(installation: installation, authentication: .authenticated,
            version: .init(installedVersion: "0.153.4", latestVersion: "0.154.0"))], to: f.runtime.defaults)
        let setup = HarnessSetupController(providers: [:], defaults: f.runtime.defaults)
        let view = host(HarnessInstallationRow(store: f.store, installation: installation, liveInstallation: installation,
            isRefreshing: false, setup: setup, install: {}).environment(f.store))
        // Popovers only present from a window that is ordered in (still offscreen).
        let window = try XCTUnwrap(view.window)
        window.orderFront(nil)
        press(try await control("Update Instructions", in: view))
        var popover: NSView?
        try await wait {
            popover = NSApp.windows.filter { $0.isVisible && $0 !== window && $0.sheetParent == nil }
                .compactMap(\.contentView).first { self.hasControl("Official Update Guide", in: $0) }
            return popover != nil
        }
        XCTAssertFalse(hasControl("Official Update Guide", in: view), "The guide must not expand the row")
        window.close()
    }

    func testAppleRowNeverOffersAnInstall() async throws {
        let f = try fixture()
        let missing = HarnessInstallation(provider: .apple, executablePath: nil)
        HarnessPresentationCache.save([.apple: .init(installation: missing, authentication: nil)], to: f.runtime.defaults)
        let setup = HarnessSetupController(providers: [.apple: AppleSetupProvider()], defaults: f.runtime.defaults)
        let view = host(HarnessInstallationRow(store: f.store, installation: missing, liveInstallation: missing,
            isRefreshing: false, setup: setup, install: {}).environment(f.store))
        _ = try await control("Local Models", in: view)
        _ = try await control("Missing from this copy of Noodle. Reinstall Noodle.", in: view)
        XCTAssertFalse(hasControl("Install…", in: view))
        XCTAssertFalse(hasControl("Install the native harness to use it with Noodle.", in: view))
    }

    func testSignInSharesTheRowOfTheOtherHarnessButtons() async throws {
        let f = try fixture()
        let installation = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
        HarnessPresentationCache.save([.codex: .init(installation: installation, authentication: .unauthenticated,
            version: .init(installedVersion: "0.153.4"))], to: f.runtime.defaults)
        let setup = HarnessSetupController(providers: [:], defaults: f.runtime.defaults)
        let view = host(HarnessInstallationRow(store: f.store, installation: installation, liveInstallation: installation,
            isRefreshing: false, setup: setup, install: {}).environment(f.store))
        let frame = { (node: NSObject) in (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
        let profilesButton = try await control("Profiles", in: view), signInButton = try await control("Sign In", in: view)
        let profiles = try XCTUnwrap(frame(profilesButton)), signIn = try XCTUnwrap(frame(signInButton))
        XCTAssertEqual(profiles.midY, signIn.midY, accuracy: 1)
        XCTAssertGreaterThan(signIn.minX, profiles.maxX)
    }

    func testSignInStaysEnabledWhileOtherHarnessesRefresh() async throws {
        let f = try fixture()
        let installation = HarnessInstallation(provider: .claudeCode, executablePath: "/fixtures/claude")
        HarnessPresentationCache.save([.claudeCode: .init(installation: installation, authentication: .unauthenticated,
            version: .init(installedVersion: "2.1.278"))], to: f.runtime.defaults)
        let provider = StalledSetupProvider()
        addTeardownBlock { @MainActor in provider.gate.resolve(.failure(CancellationError())) }
        let setup = HarnessSetupController(providers: [.claudeCode: provider], defaults: f.runtime.defaults)
        let row = { (refreshing: Bool) in
            HarnessInstallationRow(store: f.store, installation: installation, liveInstallation: installation,
                isRefreshing: refreshing, setup: setup, install: {}).environment(f.store)
        }
        // Version lookups and the other harnesses' checks must not lock this row's Sign In.
        let view = host(row(true))
        let idle = try await control("Sign In", in: view)
        XCTAssertTrue(enabled(idle))
        // Its own sign-in check may still flip the row to signed in.
        let check = Task { await setup.refresh([installation]) }
        try await wait { setup.checking.contains(.claudeCode) }
        view.rootView = row(false)
        let signIn = try await control("Sign In", in: view)
        try await wait { !self.enabled(signIn) }
        provider.gate.resolve(.success(.unauthenticated))
        await check.value
        try await wait { self.enabled(signIn) }
    }

    /// The account check only reads the saved login, so it still says signed in after the
    /// vendor refused that login; a bot waiting for sign-in is what tells.
    func testABotRefusedItsLoginShowsTheHarnessAsNeedingSignInThoughTheCheckSaysSignedIn() async throws {
        let f = try fixture(), bot = try f.runtime.start(f.a)
        let installed = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
        HarnessPresentationCache.save([.codex: .init(installation: installed, authentication: .authenticated)], to: f.runtime.defaults)
        let setup = HarnessSetupController(providers: [:], defaults: f.runtime.defaults)
        let view = host(HarnessInstallationRow(store: f.store, installation: installed, liveInstallation: installed,
            isRefreshing: false, setup: setup, install: {}).environment(f.store))
        _ = try await control("Signed in", in: view)
        XCTAssertFalse(hasControl("Sign In", in: view))
        bot.transition(.failed, failure: .authenticationRequired)
        _ = try await control("Sign-in required", in: view)
        _ = try await control("Sign In", in: view)
        bot.transition(.ready)
        _ = try await control("Signed in", in: view)
    }

    func testReconnectingAgentsShowElapsedTimeAndKickWithFailureTakingHeaderPriority() async throws {
        let f = try fixture(), first = try f.runtime.start(f.a), second = try f.runtime.start(f.b)
        let installed = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
        HarnessPresentationCache.save([.codex: .init(installation: installed, authentication: .authenticated)], to: f.runtime.defaults)
        let setup = HarnessSetupController(providers: [:], defaults: f.runtime.defaults)
        first.transition(.working, reconnectingSince: Date().addingTimeInterval(-135))
        let view = host(HarnessInstallationRow(store: f.store, installation: installed, liveInstallation: installed,
            isRefreshing: false, setup: setup, install: {}).environment(f.store))
        // Popovers only present from a window that is ordered in (still offscreen).
        let window = try XCTUnwrap(view.window)
        window.orderFront(nil)
        _ = try await control("Reconnecting", in: view)
        XCTAssertFalse(hasControl(f.a.displayName, in: view), "Affected bots are listed in the status popover")
        // The status label opens the affected bots, their elapsed time, and Kick.
        press(try await control("Show affected bots", in: view))
        var popover: NSView?
        try await wait {
            popover = NSApp.windows.filter { $0.isVisible && $0 !== window && $0.sheetParent == nil }
                .compactMap(\.contentView).first { self.hasControl(f.a.displayName, in: $0) }
            return popover != nil
        }
        let issues = try XCTUnwrap(popover)
        try await wait { self.elements(issues).flatMap { self.labels($0) }.contains { $0.hasPrefix("Reconnecting… · 2m ") } }
        let kick = try await control("Kick", in: issues)
        XCTAssertTrue(enabled(kick))
        XCTAssertFalse(hasControl("Needs attention", in: view))
        second.transition(.failed, detail: "Fixture account failure")
        _ = try await control("Needs attention", in: view)
        second.transition(.ready)
        _ = try await control("Reconnecting", in: view)
        try await wait { self.elements(issues).filter { self.matches("Kick", node: $0) }.count == 1 }
        press(try await control("Kick", in: issues))
        try await wait { f.runtime.factory.processes.count == 3 }
        XCTAssertEqual(first.stops, 1)
        _ = try await control("Signed in", in: view)
        try await wait { issues.window?.isVisible != true }
        window.close()
    }
}

@MainActor final class HarnessSignInStatusTests: HiddenViewTests {
    /// Every status about signing in opens the login's sign-in; the rest stay plain labels.
    func testSignInStatusesOfferTheirActions() {
        let menu = { (status: HarnessAuthenticationStatus?, waiting: Bool) in
            HarnessSignInMenu.make(status: status, waitingForSignIn: waiting, account: "pdp@example.com", busy: false)
        }
        XCTAssertEqual(menu(.authenticated, false), HarnessSignInMenu(account: "pdp@example.com", actions: [.signInAgain, .signOut]))
        XCTAssertEqual(menu(.unauthenticated, false), HarnessSignInMenu(account: nil, actions: [.signIn]))
        XCTAssertEqual(menu(.unauthenticated, true), HarnessSignInMenu(account: nil, actions: [.signIn]))
        // A refused login still reads as signed in, so it can be signed out of as well as in to.
        XCTAssertEqual(menu(.authenticated, true), HarnessSignInMenu(account: nil, actions: [.signIn, .signOut]))
        XCTAssertEqual(menu(.managedExternally, false), HarnessSignInMenu(account: nil, actions: [.signIn, .signOut]))
        XCTAssertNil(menu(.notRequired, false), "Ready is not about signing in")
        XCTAssertNil(menu(nil, false), "Checking or installed is not about signing in")
        XCTAssertNil(HarnessSignInMenu.make(status: .authenticated, waitingForSignIn: false, account: nil, busy: true))
    }

    /// "Signed in" opens the account the Default login is signed in to, with Sign In Again and Sign Out.
    func testSignedInStatusOpensTheDefaultLoginsAccountAndSignOut() async throws {
        let f = try fixture()
        let installed = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
        HarnessPresentationCache.save([.codex: .init(installation: installed, authentication: .unauthenticated)], to: f.runtime.defaults)
        let provider = NamedAccountSetupProvider()
        let setup = HarnessSetupController(providers: [.codex: provider], defaults: f.runtime.defaults, signOut: { _ in })
        let view = host(HarnessInstallationRow(store: f.store, installation: installed, liveInstallation: installed,
            isRefreshing: false, setup: setup, install: {}).environment(f.store))
        let window = try XCTUnwrap(view.window)
        window.orderFront(nil)
        _ = try await control("Sign-in required", in: view)
        press(try await control("Show sign-in", in: view))
        var panel = try await popover(containing: "Sign In", besides: window)
        XCTAssertFalse(hasControl("Sign Out", in: panel), "Nothing to sign out of")
        press(try await control("Sign In", in: panel))
        try await wait { panel.window?.isVisible != true }
        _ = try await control("Signed in", in: view)
        XCTAssertEqual(setup.accounts[.codex], "pdp@example.com")
        press(try await control("Show sign-in", in: view))
        panel = try await popover(containing: "pdp@example.com", besides: window)
        for name in ["Default", "Sign In Again", "Sign Out"] { _ = try await control(name, in: panel) }
        XCTAssertFalse(hasControl("Kick", in: panel), "No bot is in trouble")
        window.close()
    }

    /// A bot in trouble comes first, then the login's sign-in.
    func testNeedsAttentionListsTheBotsBeforeTheSignIn() async throws {
        let f = try fixture(), bot = try f.runtime.start(f.a)
        let installed = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
        HarnessPresentationCache.save([.codex: .init(installation: installed, authentication: .authenticated)], to: f.runtime.defaults)
        let setup = HarnessSetupController(providers: [:], defaults: f.runtime.defaults)
        bot.transition(.failed, detail: "Fixture account failure")
        let view = host(HarnessInstallationRow(store: f.store, installation: installed, liveInstallation: installed,
            isRefreshing: false, setup: setup, install: {}).environment(f.store))
        let window = try XCTUnwrap(view.window)
        window.orderFront(nil)
        _ = try await control("Needs attention", in: view)
        press(try await control("Show affected bots", in: view))
        let panel = try await popover(containing: f.a.displayName, besides: window)
        let frame = { (node: NSObject) in (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
        let kickButton = try await control("Kick", in: panel), signOutButton = try await control("Sign Out", in: panel)
        let kick = try XCTUnwrap(frame(kickButton)), signOut = try XCTUnwrap(frame(signOutButton))
        XCTAssertGreaterThan(kick.minY, signOut.maxY, "Bots first, in screen coordinates that grow upwards")
        window.close()
    }

    private func popover(containing name: String, besides window: NSWindow) async throws -> NSView {
        var popover: NSView?
        try await wait {
            popover = NSApp.windows.filter { $0.isVisible && $0 !== window && $0.sheetParent == nil }
                .compactMap(\.contentView).first { self.hasControl(name, in: $0) }
            return popover != nil
        }
        return try XCTUnwrap(popover)
    }
}

/// Signs in to an account it names, as Codex and Claude Code checks do.
@MainActor private final class NamedAccountSetupProvider: HarnessSetupProviding, HarnessAccountNaming {
    let installationGuide = HarnessInstallationGuide(command: nil, instructions: "Fixture instructions", documentationURL: URL(string: "https://example.invalid/setup")!)
    var onAccount: (@MainActor (String) -> Void)?
    var signedIn = false
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        guard signedIn else { return .unauthenticated }
        onAccount?("pdp@example.com")
        return .authenticated
    }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        signedIn = true
        return try await status(for: installation)
    }
}

@MainActor private final class StalledSetupProvider: HarnessSetupProviding {
    let installationGuide = HarnessInstallationGuide(command: nil, instructions: "Fixture instructions", documentationURL: URL(string: "https://example.invalid/setup")!)
    let gate = RoutingGate<HarnessAuthenticationStatus>()
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus { try await gate.value() }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus { .authenticated }
}
