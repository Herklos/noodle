import CryptoKit
import SQLite3
import XCTest
@testable import NoodleCore

final class HarnessProfileTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var store: HarnessProfileStore { repository.harnessProfiles }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-profiles-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("Noodle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    func testProfilesKeepTheirLoginInsideTheirOwnFolder() throws {
        XCTAssertEqual(try store.load(), [])
        let work = try store.create(provider: .codex, named: "  Work  ", now: Date(timeIntervalSince1970: 1))
        let personal = try store.create(provider: .codex, named: "Personal", now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(try store.load().map(\.displayName), ["Work", "Personal"])
        XCTAssertEqual(store.accountHome(work).path,
            root.appendingPathComponent("HarnessProfiles/\(work.id.uuidString.lowercased())/home/.codex").path)
        XCTAssertEqual(try String(contentsOf: store.accountHome(work).appendingPathComponent("config.toml"), encoding: .utf8),
            "cli_auth_credentials_store = \"file\"\n")

        XCTAssertEqual(try store.rename(work, to: "Client").displayName, "Client")
        try store.delete(personal)
        XCTAssertEqual(try store.load().map(\.displayName), ["Client"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.loginHome(personal).path))

        XCTAssertThrowsError(try store.create(provider: .apple, named: "Other"))
        XCTAssertThrowsError(try store.create(provider: .codex, named: " \n "))
    }

    func testBotSelectionIsPrivateAndSurvivesRecordUpdates() throws {
        var agent = try repository.createAgent(named: "Profile Bot", harnessIdentifier: "codex").agent
        let workspace = repository.storage(for: agent.id).workspace
        XCTAssertNil(try store.selected(workspace: workspace, provider: .codex))
        XCTAssertFalse(try String(contentsOf: repository.storage(for: agent.id).configuration, encoding: .utf8).contains("harnessProfile"))

        let profile = try store.create(provider: .codex, named: "Work")
        try repository.updateAgentHarnessProfile(agent, profile: profile.id)
        agent = try repository.renameAgent(agent, to: "Renamed Bot")
        XCTAssertEqual(try repository.loadAgentHarnessProfile(agent), profile.id)
        XCTAssertEqual(try store.selected(workspace: workspace, provider: .codex), profile)
        XCTAssertFalse(try XCTUnwrap(String(data: JSONEncoder().encode(agent), encoding: .utf8)).contains(profile.id.uuidString))

        try repository.updateAgentHarnessProfile(agent, profile: nil)
        XCTAssertNil(try store.selected(workspace: workspace, provider: .codex))
    }

    func testUnavailableProfileFailsClosed() throws {
        let agent = try repository.createAgent(named: "Profile Bot", harnessIdentifier: "codex").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .codex, named: "Work")
        try repository.updateAgentHarnessProfile(agent, profile: profile.id)

        // A profile belongs to its own harness. On another one, as a fallback when its own
        // runs out of usage, the bot uses that harness's own login.
        XCTAssertNil(try store.selected(workspace: workspace, provider: .claudeCode))

        // A redirected login home must not stand in for the profile.
        let home = store.loginHome(profile), moved = home.deletingLastPathComponent().appendingPathComponent("moved")
        try FileManager.default.moveItem(at: home, to: moved)
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: moved)
        XCTAssertThrowsError(try store.selected(workspace: workspace, provider: .codex))
        try FileManager.default.removeItem(at: home)
        try FileManager.default.moveItem(at: moved, to: home)
        XCTAssertEqual(try store.selected(workspace: workspace, provider: .codex), profile)

        try store.delete(profile)
        XCTAssertThrowsError(try store.selected(workspace: workspace, provider: .codex)) {
            XCTAssertTrue($0.localizedDescription.contains("profile is unavailable"))
        }
    }

    func testEachHarnessIsPointedAtItsOwnProfileFolder() throws {
        let codex = try store.create(provider: .codex, named: "Codex"), grok = try store.create(provider: .grokBuild, named: "Grok")
        let muse = try store.create(provider: .muse, named: "Muse"), claude = try store.create(provider: .claudeCode, named: "Claude")
        XCTAssertEqual(store.environment(codex), ["CODEX_HOME": store.loginHome(codex).appendingPathComponent(".codex").path])
        XCTAssertEqual(store.environment(grok), ["GROK_HOME": store.loginHome(grok).appendingPathComponent(".grok").path])
        XCTAssertEqual(store.environment(muse), ["XDG_CONFIG_HOME": store.loginHome(muse).appendingPathComponent(".config").path,
                                                 "TBH_CREDENTIAL_BACKEND": "file"])
        XCTAssertEqual(store.environment(claude), ["CLAUDE_CONFIG_DIR": store.loginHome(claude).appendingPathComponent(".claude").path])
        XCTAssertEqual(store.accountHome(muse).path, store.loginHome(muse).appendingPathComponent(".config/muse").path)
        for profile in [codex, grok, muse, claude] {
            XCTAssertEqual(try store.validated(profile.id), profile)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.accountHome(profile).path))
        }
        // A link anywhere between the login home and the account folder is refused.
        let config = store.loginHome(muse).appendingPathComponent(".config"), moved = store.loginHome(muse).appendingPathComponent("moved")
        try FileManager.default.moveItem(at: config, to: moved)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: moved)
        XCTAssertThrowsError(try store.validated(muse.id))
    }

    func testOpenCodeProfileKeepsItsLoginDatabaseInItsOwnFolder() throws {
        let profile = try store.create(provider: .openCode, named: "Work")
        let home = store.loginHome(profile)
        // The background service is found through the state folder, so every folder moves.
        XCTAssertEqual(store.environment(profile), [
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path])
        XCTAssertEqual(store.accountHome(profile).path, home.appendingPathComponent(".local/share/opencode").path)
        XCTAssertEqual(try store.validated(profile.id), profile)
    }

    func testOpenCodeProfileIsSignedInOnlyByItsOwnDatabase() throws {
        let work = try store.create(provider: .openCode, named: "Work"), other = try store.create(provider: .openCode, named: "Other")
        XCTAssertFalse(try store.openCodeSignedIn(work))
        // The database OpenCode writes under XDG_DATA_HOME is the one read for status.
        let data = URL(fileURLWithPath: try XCTUnwrap(store.environment(work)["XDG_DATA_HOME"]))
        try openCodeLogin(data.deletingLastPathComponent().deletingLastPathComponent(), key: "work-key")
        XCTAssertTrue(try store.openCodeSignedIn(work))
        XCTAssertFalse(try store.openCodeSignedIn(other))
    }

    func testRestrictedOpenCodeBotIsSeededFromItsProfileNotTheSystemLogin() throws {
        let agent = try repository.createAgent(named: "OpenCode Bot", harnessIdentifier: "opencode").agent
        let workspace = repository.storage(for: agent.id).workspace
        try OpenCodeStorage.prepareDirectories(workspace: workspace)
        let system = root.deletingLastPathComponent().appendingPathComponent("system-home", isDirectory: true)
        try openCodeLogin(system, key: "system-key")
        let profile = try store.create(provider: .openCode, named: "Work")
        try openCodeLogin(store.loginHome(profile), key: "work-key")
        // Stands in for OpenCode creating its schema; the host then writes the rows.
        let executable = root.deletingLastPathComponent().appendingPathComponent("opencode")
        try Data(#"""
            #!/bin/sh
            exec /usr/bin/sqlite3 "$XDG_DATA_HOME/opencode/opencode.db" "CREATE TABLE IF NOT EXISTS credential (id TEXT, integration_id TEXT, label TEXT, value TEXT, active INT, time_created INT, time_updated INT);"
            """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        func seed(_ harnessProfile: HarnessProfile?) throws -> String {
            _ = try OpenCodeStorage.seed(workspace: workspace, harnessProfile: harnessProfile, profiles: store, system: system,
                executable: executable, environment: OpenCodeStorage.environment(workspace: workspace),
                profile: "(version 1)(allow default)")
            return String(describing: try OpenCodeStorage.credentials(home: RestrictedHarnessStorage.home(workspace: workspace)))
        }
        XCTAssertTrue(try seed(profile).contains("work-key"))
        XCTAssertFalse(try seed(profile).contains("system-key"))
        XCTAssertTrue(try seed(nil).contains("system-key"))
    }

    private func openCodeLogin(_ home: URL, key: String) throws {
        let url = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(url.path, &db) == SQLITE_OK, sqlite3_exec(db, """
            CREATE TABLE credential (id TEXT, integration_id TEXT, value TEXT, active INT, time_created INT);
            INSERT INTO credential VALUES ('cred_\(key.prefix(4))', 'anthropic', '{"type":"key","key":"\(key)"}', 1, 10);
            """, nil, nil, nil) == SQLITE_OK else { throw HarnessSetupError("Fixture database failed") }
    }

    func testSignInChallengeAcceptsOnlyTheVendorsDevicePage() throws {
        let grok = "\nTo sign in, open this URL in your browser:\n\n  https://accounts.x.ai/oauth2/device?user_code=7ABC-DEFG\n\nConfirm this code in your browser:\n\n  7ABC-DEFG\n\nWaiting"
        let challenge = try XCTUnwrap(HarnessProfileLogin.challenge(provider: .grokBuild, text: grok))
        XCTAssertEqual(challenge.code, "7ABC-DEFG")
        XCTAssertEqual(challenge.url.absoluteString, "https://accounts.x.ai/oauth2/device?user_code=7ABC-DEFG")
        let muse = "Open this page to sign in:\n  https://auth.meta.com/oauth/device/?code=ABCD-EFGH\nconfirm this code matches:\n  ABCD-EFGH\n"
        XCTAssertEqual(HarnessProfileLogin.challenge(provider: .muse, text: muse)?.code, "ABCD-EFGH")

        // A read that ends inside the URL line waits for the rest.
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .muse, text: "  https://auth.meta.com/oauth/device/?code=ABCD"))
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .grokBuild, text: muse))
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .codex, text: grok))
        for url in ["http://accounts.x.ai/oauth2/device?user_code=7ABC-DEFG", "https://accounts.x.ai.evil.example/oauth2/device",
                    "https://user@accounts.x.ai/oauth2/device", "https://accounts.x.ai:8443/oauth2/device", "https://accounts.x.ai/other"] {
            XCTAssertNil(HarnessProfileLogin.challenge(provider: .grokBuild, url: url, code: "7ABC-DEFG"), url)
        }
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .grokBuild, url: "https://accounts.x.ai/oauth2/device", code: "7ABC DEFG; rm"))
    }

    func testMuseProfileNeverFallsBackToTheSharedKeychainLogin() throws {
        let agent = try repository.createAgent(named: "Muse Bot", harnessIdentifier: "muse").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .muse, named: "Work")
        let auth = store.accountHome(profile).appendingPathComponent("auth.json")
        func write(_ meta: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: ["schema_version": 1, "providers": ["meta": meta]]).write(to: auth)
        }
        XCTAssertFalse(store.loginIsShared(profile))

        try write(["mechanism": "oauth", "storage": "keychain"])
        XCTAssertTrue(store.loginIsShared(profile))
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .muse, workspace: workspace,
            loginHome: store.loginHome(profile), secret: { _, _ in nil }))

        try write(["mechanism": "oauth", "storage": "file", "access_token": "work-token"])
        XCTAssertFalse(store.loginIsShared(profile))
        try RestrictedHarnessStorage.prepare(provider: .muse, workspace: workspace, loginHome: store.loginHome(profile),
            secret: { _, _ in XCTFail("A profile must not read the Keychain"); return nil })
        let seeded = RestrictedHarnessStorage.home(workspace: workspace).appendingPathComponent(".config/muse/auth.json")
        XCTAssertTrue(try String(contentsOf: seeded, encoding: .utf8).contains("work-token"))
    }

    func testRestrictedBotIsSeededFromItsProfileLogin() throws {
        let agent = try repository.createAgent(named: "Profile Bot", harnessIdentifier: "codex").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .codex, named: "Work")
        let seeded = RestrictedHarnessStorage.home(workspace: workspace).appendingPathComponent(".codex/auth.json")

        // Not signed in yet: never fall back to another account.
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: store.loginHome(profile)))

        try Data("work-login".utf8).write(to: store.accountHome(profile).appendingPathComponent("auth.json"))
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: store.loginHome(profile))
        XCTAssertEqual(try Data(contentsOf: seeded), Data("work-login".utf8))

        // Switching profile replaces the bot's login with the other account.
        let other = try store.create(provider: .codex, named: "Personal")
        try Data("personal-login".utf8).write(to: store.accountHome(other).appendingPathComponent("auth.json"))
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: store.loginHome(other))
        XCTAssertEqual(try Data(contentsOf: seeded), Data("personal-login".utf8))
    }

    func testFxProfileKeepsItsLoginInFilesUnderItsOwnHome() throws {
        let agent = try repository.createAgent(named: "FX Bot", harnessIdentifier: "fx").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .fx, named: "Work")
        XCTAssertEqual(try store.validated(profile.id), profile)
        XCTAssertEqual(store.environment(profile), ["HOME": store.loginHome(profile).path, "FX_DISABLE_KEYCHAIN": "1"])
        XCTAssertEqual(store.accountHome(profile).path, store.loginHome(profile).appendingPathComponent(".fx").path)

        // Not signed in yet: the user's own FX Keychain items never stand in.
        let secret = store.loginSecret(profile, read: { _, _ in XCTFail("An FX profile must not read the Keychain"); return nil })
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .fx, workspace: workspace,
            loginHome: store.loginHome(profile), secret: secret))

        try Data("work-session".utf8).write(to: store.accountHome(profile).appendingPathComponent("auth.json"))
        try RestrictedHarnessStorage.prepare(provider: .fx, workspace: workspace, loginHome: store.loginHome(profile), secret: secret)
        let seeded = RestrictedHarnessStorage.home(workspace: workspace).appendingPathComponent(".fx/auth.json")
        XCTAssertEqual(try Data(contentsOf: seeded), Data("work-session".utf8))
    }

    func testFxProfileSignInAndStatusUseTheProfilesHome() throws {
        let profile = try store.create(provider: .fx, named: "Work")
        let userHome = root.deletingLastPathComponent().appendingPathComponent("user-home", isDirectory: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        let fx = root.deletingLastPathComponent().appendingPathComponent("fx")
        try Data(#"""
        #!/bin/sh
        case "$*" in
        login) mkdir -p "$HOME/.fx" && printf '%s' "$FX_DISABLE_KEYCHAIN" > "$HOME/.fx/auth.json"
               printf 'Open https://vercel.com/device\nCode: ABCD-EFGH\n' ;;
        'status --json') [ -f "$HOME/.fx/auth.json" ] && auth=stored || auth=missing
               printf '{"kind":"status","auth":"%s"}' "$auth" ;;
        *) exit 41 ;;
        esac
        """#.utf8).write(to: fx)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.path)
        // What the Agent Host gives every account command, with the user's home.
        let environment = store.environment(profile, over: ["HOME": userHome.path, "PATH": "/usr/bin:/bin"])
        XCTAssertFalse(try FxInspection.status(executable: fx, environment: environment).authenticated)

        let login = Process(), output = Pipe()
        login.executableURL = fx
        login.arguments = ["login"]
        login.environment = environment
        login.standardOutput = output
        try login.run()
        login.waitUntilExit()
        let challenge = FxProtocol.loginChallenge(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(challenge?.code, "ABCD-EFGH")

        XCTAssertEqual(try String(contentsOf: store.accountHome(profile).appendingPathComponent("auth.json"), encoding: .utf8), "1")
        XCTAssertTrue(try FxInspection.status(executable: fx, environment: environment).authenticated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: userHome.path), [])
        XCTAssertFalse(try FxInspection.status(executable: fx, environment: ["HOME": userHome.path]).authenticated)
    }

    func testRestrictedClaudeBotIsSeededOnlyFromItsProfileKeychainItem() throws {
        let agent = try repository.createAgent(named: "Claude Bot", harnessIdentifier: "claude-code").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .claudeCode, named: "Work")
        // Claude Code names the item after its configuration folder.
        let digest = SHA256.hash(data: Data(store.accountHome(profile).path.utf8)).map { String(format: "%02x", $0) }.joined()
        let service = "Claude Code-credentials-" + digest.prefix(8)
        var requested: [String] = []
        func read(_ name: String, _ account: String) throws -> Data? {
            requested.append(name)
            return name == service ? Data(#"{"claudeAiOauth":{"accessToken":"work-token"},"mcpOAuth":{}}"#.utf8) : nil
        }
        try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: store.loginHome(profile),
                                             secret: store.loginSecret(profile, read: read))
        XCTAssertEqual(requested, [service])
        let seeded = RestrictedHarnessStorage.home(workspace: workspace).appendingPathComponent(".claude/.credentials.json")
        XCTAssertEqual(try String(contentsOf: seeded, encoding: .utf8), #"{"claudeAiOauth":{"accessToken":"work-token"}}"#)

        // Other harnesses keep a profile's login in its files alone.
        let codex = try store.create(provider: .codex, named: "Codex")
        XCTAssertNil(try store.loginSecret(codex, read: { _, _ in XCTFail("A Codex profile must not read the Keychain"); return nil })(
            "Claude Code-credentials", NSUserName()))
    }

    func testProfileClaudeKeychainItemIsReadWithTheSecurityTool() throws {
        var arguments: [String] = []
        let data = try RestrictedHarnessStorage.readSecret(service: "Claude Code-credentials-0123abcd", account: "me") {
            arguments = $0
            return (0, Data("login\n".utf8))
        }
        XCTAssertEqual(arguments, ["find-generic-password", "-s", "Claude Code-credentials-0123abcd", "-a", "me", "-w"])
        XCTAssertEqual(data, Data("login".utf8))
    }
}
