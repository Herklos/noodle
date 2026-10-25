import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The trusted host copies login material only. Native histories, settings,
/// hooks, MCP connections, and skills are never imported from a shared account.
public enum RestrictedHarnessStorage {
    public static func home(workspace: URL) -> URL { workspace.appendingPathComponent(".noodle/home") }

    public static func prepare(provider: HarnessProvider, workspace: URL, loginHome: URL,
                               secret: (String, String) throws -> Data? = readSecret,
                               writeSecret: ((String, String, Data) throws -> Void)? = nil) throws {
        _ = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home", create: true)
        _ = try WorkspaceMailbox(workspace: workspace, path: ".noodle/tmp", create: true)
        guard provider != .apple else { return }
        if provider == .openCode { try OpenCodeStorage.prepareDirectories(workspace: workspace); return }
        guard let accountPath = accountPath(provider) else { throw HarnessSetupError("Unsupported restricted harness storage.") }
        let destination = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/" + accountPath, create: true)
        let runtime = try WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime")
        let shared = try SharedLogin(provider: provider, workspace: workspace, loginHome: loginHome, accountPath: accountPath)
        func seed(_ data: Data, name: String) throws {
            let stamp = "auth-seed-\(provider.rawValue)-\(name).sha256"
            let fingerprint = Data(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().utf8)
            if destination.contains(name), (try? runtime.read(stamp, limit: 128)) == fingerprint { return }
            try destination.writeData(data, named: name)
            try runtime.writeData(fingerprint, named: stamp)
        }
        func share(_ name: String, from origin: SharedLogin.Origin = .file, writeBack: ((Data) throws -> Data?)? = nil) throws {
            guard try shared.exchange(name, from: origin, destination: destination, runtime: runtime, writeBack: writeBack)
            else { throw missing(provider) }
        }
        func sourceData(_ name: String) throws -> Data? {
            let source = try WorkspaceMailbox(workspace: loginHome, path: accountPath)
            return source.contains(name) ? try source.read(name, limit: 1_048_576) : nil
        }
        switch provider {
        case .claudeCode:
            // Noodle's sign-in uses the standard Claude.ai account. The native
            // CLI prefers this exact Keychain item, with a file fallback.
            guard let data = try secret("Claude Code-credentials", NSUserName()) ?? sourceData(".credentials.json"),
                  let login = try claudeLogin(data) else { throw missing(provider) }
            try withoutActuallyEscaping(secret) { secret in
                try share(".credentials.json", from: .item(login),
                          writeBack: writeSecret.map { claudeWriteBack(over: login, secret: secret, write: $0) })
            }
        case .codex, .grokBuild:
            try share("auth.json")
            if provider == .codex {
                let routing = try CodexModelRouting(config: sourceData("config.toml"), codexHome: loginHome.appendingPathComponent(accountPath))
                if let catalogue = routing.catalogue { try seed(catalogue, name: CodexModelRouting.catalogueName) }
                try seed(Data(("cli_auth_credentials_store = \"file\"\n"
                    + routing.config(catalogue: destination.url.appendingPathComponent(CodexModelRouting.catalogueName))).utf8),
                    name: "config.toml")
            }
        case .fx:
            let settings = try sourceData("settings.json").flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            // Only provider/model selection is carried across, never executable configuration.
            var selected = settings.filter { ["provider", "credential_source", "models", "effort", "fast_mode"].contains($0.key) }
            selected["auto_upgrade"] = false
            switch settings["provider"] as? String ?? "gateway" {
            case "codex", "chatgpt": try share("chatgpt-auth.json")
            case "grok": try share("grok-auth.json")
            default:
                if settings["credential_source"] as? String == "stored_key" {
                    if try sourceData("api-key") != nil { try share("api-key") }
                    else if let key = try secret("FX_AI_GATEWAY_API_KEY", NSUserName()) { try share("api-key", from: .item(key)) }
                    else { throw missing(provider) }
                    selected["credential_source"] = "ai_gateway_api_key"
                } else if try sourceData("auth.json") != nil {
                    try share("auth.json")
                } else if let session = try secret("FX_OAUTH_SESSION_V1", NSUserName()) {
                    try share("auth.json", from: .item(session))
                } else { throw missing(provider) }
            }
            try seed(JSONSerialization.data(withJSONObject: selected, options: [.sortedKeys]), name: "settings.json")
        case .muse:
            guard let data = try sourceData("auth.json"),
                  var auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let providers = auth["providers"] as? [String: Any],
                  var meta = providers["meta"] as? [String: Any] else { throw missing(provider) }
            if meta["storage"] as? String == "keychain" {
                guard let data = try secret("ai.meta.dev.credentials", "meta"),
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw missing(provider) }
                for (key, value) in payload where key != "secret_schema_version" { meta[key] = value }
            }
            meta["storage"] = "file"
            auth["providers"] = ["meta": meta]
            try share("auth.json", from: .item(JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])))
        case .antigravity:
            // The CLI keeps its login in this Keychain item, or in this file when the
            // Keychain is out of reach, as it is for a profile and inside the sandbox.
            if let login = try secret("gemini", "antigravity").flatMap(AntigravityProtocol.fileLogin) {
                try share("antigravity-oauth-token", from: .item(login))
            } else {
                try share("antigravity-oauth-token")
            }
        default: break
        }
        for name in loginNames(provider) where runtime.contains(failedStamp(provider, name)) {
            guard (try? runtime.read(failedStamp(provider, name), limit: 256)) != (try? runtime.read(SharedLogin.stamp(provider, name), limit: 256)) else {
                throw refused(provider)
            }
            runtime.remove(failedStamp(provider, name))
        }
    }

    /// Hands a login a running bot refreshed to the login it shares, and the
    /// shared login to the bot. A Keychain login the person's own harness
    /// refreshed meanwhile replaces both, since its refresh spent the bot's token.
    /// Given `writeSecret`, a bot's refresh goes into the Keychain item too, since
    /// it spent the token the person's own harness holds there.
    public static func exchange(provider: HarnessProvider, workspace: URL, loginHome: URL,
                                secret: (String, String) throws -> Data? = { _, _ in nil },
                                writeSecret: ((String, String, Data) throws -> Void)? = nil) throws {
        guard let accountPath = accountPath(provider) else { return }
        let destination = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/" + accountPath)
        let runtime = try WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime")
        let shared = try SharedLogin(provider: provider, workspace: workspace, loginHome: loginHome, accountPath: accountPath)
        let item: Data? = switch provider {
        case .claudeCode: (try? secret("Claude Code-credentials", NSUserName())).flatMap { try? claudeLogin($0) }
        case .antigravity: (try? secret("gemini", "antigravity")).flatMap(AntigravityProtocol.fileLogin)
        default: nil
        }
        try withoutActuallyEscaping(secret) { secret in
            let writeBack = provider == .claudeCode ? item.flatMap { login in
                writeSecret.map { claudeWriteBack(over: login, secret: secret, write: $0) }
            } : nil
            for name in loginNames(provider) where shared.holds(name, runtime: runtime) {
                _ = try shared.exchange(name, from: item.map { .item($0) } ?? .unknown, destination: destination, runtime: runtime,
                                        writeBack: writeBack)
            }
        }
    }

    /// Notes that the login the bot holds was refused. Starting again on it cannot
    /// work and would only show the bot as ready, so `prepare` refuses until a new
    /// sign-in or another bot's refresh replaces it.
    public static func loginFailed(provider: HarnessProvider, workspace: URL) throws {
        let runtime = try WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime")
        for name in loginNames(provider) where runtime.contains(SharedLogin.stamp(provider, name)) {
            try runtime.writeData(runtime.read(SharedLogin.stamp(provider, name), limit: 256), named: failedStamp(provider, name))
        }
    }

    /// Whether the next start would hand the bot the login it was refused with, asked
    /// before the start so the bot never shows as ready on it. Only Claude Code notes
    /// refused logins.
    public static func refusedAgain(provider: HarnessProvider, workspace: URL, loginHome: URL,
                                    secret: (String, String) throws -> Data? = readSecret) -> Bool {
        guard provider == .claudeCode, let accountPath = accountPath(provider),
              let runtime = try? WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime"),
              let refused = try? runtime.read(failedStamp(provider, ".credentials.json"), limit: 256),
              let shared = try? SharedLogin(provider: provider, workspace: workspace, loginHome: loginHome, accountPath: accountPath)
        else { return false }
        let source = try? WorkspaceMailbox(workspace: loginHome, path: accountPath)
        let file = source.flatMap { $0.contains(".credentials.json") ? try? $0.read(".credentials.json", limit: 1_048_576) : nil }
        guard let data = (try? secret("Claude Code-credentials", NSUserName())) ?? file,
              let login = try? claudeLogin(data) else { return false }
        let destination = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/" + accountPath)
        return shared.next(".credentials.json", from: .item(login), destination: destination, runtime: runtime)
            .map(shared.tag) == refused
    }

    /// Worded so the runtime recognises it as a sign-in failure.
    public static func refused(_ provider: HarnessProvider) -> HarnessSetupError {
        HarnessSetupError("Not logged in: \(provider.displayName) refused this login and nobody has signed in since. Sign in to the harness, then retry.")
    }

    private static func failedStamp(_ provider: HarnessProvider, _ name: String) -> String {
        "auth-failed-\(provider.rawValue)-\(name).sha256"
    }

    /// Replaces only the Claude.ai login in the item, and only while the item still
    /// holds the login the bot refreshed from; a new sign-in there wins instead.
    /// Returns the login now in the item.
    private static func claudeWriteBack(over login: Data, secret: @escaping (String, String) throws -> Data?,
                                        write: @escaping (String, String, Data) throws -> Void) -> (Data) throws -> Data? {
        { copy in
            func oauth(_ data: Data) throws -> [String: Any]? {
                (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["claudeAiOauth"] as? [String: Any]
            }
            guard let refreshed = try claudeLogin(copy), let new = try oauth(refreshed), let old = try oauth(login),
                  let token = new["refreshToken"] as? String, !token.isEmpty, token != old["refreshToken"] as? String,
                  let current = try secret("Claude Code-credentials", NSUserName()), try claudeLogin(current) == login,
                  var payload = try JSONSerialization.jsonObject(with: current) as? [String: Any] else { return nil }
            payload["claudeAiOauth"] = new
            try write("Claude Code-credentials", NSUserName(), JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            return refreshed
        }
    }

    /// Only the Claude.ai OAuth login, never other integrations in the payload.
    private static func claudeLogin(_ data: Data) throws -> Data? {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = payload["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
    }

    /// Codex routes every model through the one provider its config selects, so
    /// custom models need that choice, the provider tables and the model catalogue.
    /// Nothing else is carried, and neither is a provider's `auth` command.
    struct CodexModelRouting {
        static let catalogueName = "model-catalog.json"
        private(set) var provider: String?
        private(set) var tables: [String] = []
        private(set) var catalogue: Data?

        init(config: Data?, codexHome: URL) throws {
            guard let config else { return }
            var table: [String]?, keep = false, depth = 0, multiline: String?
            func close() {
                guard keep, var table else { return }
                while table.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { table.removeLast() }
                tables.append(table.joined(separator: "\n"))
            }
            for line in String(decoding: config, as: UTF8.self).components(separatedBy: .newlines) {
                if let delimiter = multiline {
                    if keep { table?.append(line) }
                    if line.contains(delimiter) { multiline = nil }
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    close()
                    let path = trimmed.hasPrefix("[[") ? [] : Self.headerPath(trimmed)
                    keep = path.count >= 2 && path[0] == "model_providers" && !path.dropFirst(2).contains("auth")
                    depth = path.count
                    table = [line]
                    continue
                }
                if let delimiter = ["\"\"\"", "'''"].first(where: { trimmed.components(separatedBy: $0).count == 2 }) {
                    multiline = delimiter
                }
                if table == nil {
                    switch Self.key(trimmed) {
                    case "model_provider": provider = Self.string(trimmed)
                    case "model_catalog_json": catalogue = try Self.string(trimmed).flatMap { try Self.catalogue($0, codexHome: codexHome) }
                    default: break
                    }
                } else if keep, depth > 2 || Self.key(trimmed) != "auth" {
                    table?.append(line)
                }
            }
            close()
        }

        func config(catalogue path: URL) -> String {
            var lines: [String] = []
            if let provider { lines.append("model_provider = " + Self.quoted(provider)) }
            if catalogue != nil { lines.append("model_catalog_json = " + Self.quoted(path.path)) }
            return (lines + tables.map { "\n" + $0 }).map { $0 + "\n" }.joined()
        }

        private static func key(_ line: String) -> String? {
            guard let equals = line.firstIndex(of: "=") else { return nil }
            return line[..<equals].trimmingCharacters(in: .whitespaces)
        }

        /// A single-line basic or literal string value; anything else is ignored.
        private static func string(_ line: String) -> String? {
            guard let equals = line.firstIndex(of: "=") else { return nil }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("'"), let end = value.dropFirst().firstIndex(of: "'") {
                return String(value[value.index(after: value.startIndex)..<end])
            }
            guard value.hasPrefix("\"") else { return nil }
            // TOML basic strings escape like JSON strings; read up to the closing quote.
            var escaped = false, end: String.Index?
            for index in value.indices.dropFirst() {
                if escaped { escaped = false } else if value[index] == "\\" { escaped = true } else if value[index] == "\"" { end = index; break }
            }
            guard let end else { return nil }
            value = String(value[...end])
            return try? JSONDecoder().decode(String.self, from: Data(value.utf8))
        }

        private static func quoted(_ value: String) -> String {
            String(decoding: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
                .replacingOccurrences(of: "\\/", with: "/")
        }

        private static func headerPath(_ header: String) -> [String] {
            guard let close = header.lastIndex(of: "]") else { return [] }
            var parts: [String] = [], current = "", quote: Character?
            for character in header[header.index(after: header.startIndex)..<close] {
                if let open = quote {
                    if character == open { quote = nil } else { current.append(character) }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "." {
                    parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                } else {
                    current.append(character)
                }
            }
            return parts + [current.trimmingCharacters(in: .whitespaces)]
        }

        private static func catalogue(_ path: String, codexHome: URL) throws -> Data? {
            let expanded = (path as NSString).expandingTildeInPath
            let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : codexHome.appendingPathComponent(expanded))
                .resolvingSymlinksInPath()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            guard (attributes[.size] as? NSNumber)?.intValue ?? .max <= 4_194_304 else {
                throw HarnessSetupError("Codex’s model catalogue is too large.")
            }
            return try Data(contentsOf: url)
        }
    }

    private static func accountPath(_ provider: HarnessProvider) -> String? {
        switch provider {
        case .codex: ".codex"
        case .claudeCode: ".claude"
        case .fx: ".fx"
        case .grokBuild: ".grok"
        case .muse: ".config/muse"
        case .antigravity: ".gemini/antigravity-cli"
        default: nil
        }
    }

    private static func loginNames(_ provider: HarnessProvider) -> [String] {
        switch provider {
        case .codex, .grokBuild, .muse: ["auth.json"]
        case .claudeCode: [".credentials.json"]
        case .fx: ["chatgpt-auth.json", "grok-auth.json", "api-key", "auth.json"]
        case .antigravity: ["antigravity-oauth-token"]
        default: []
        }
    }

    /// Every bot on one login holds a copy of it. Refresh tokens are single use,
    /// so the first copy to refresh spends the token the others hold. Whatever a
    /// bot refreshed is handed back here and reaches the others before they need it.
    private struct SharedLogin {
        enum Origin {
            case file
            /// Read from the Keychain or rewritten on the way.
            case item(Data)
            /// Between starts: wherever the bot's last start put it.
            case unknown
        }

        let provider: HarnessProvider
        let key: String
        /// A login read from a file is shared in that file, which keeps the
        /// harness's own sign-in working too.
        let source: WorkspaceMailbox?
        /// A login taken from the Keychain, or rewritten on the way, is shared in
        /// Noodle's storage beside a note of the item it came from.
        let copies: WorkspaceMailbox

        init(provider: HarnessProvider, workspace: URL, loginHome: URL, accountPath: String) throws {
            self.provider = provider
            let identity = provider.rawValue + "\n" + loginHome.standardizedFileURL.path + "\n" + accountPath
            key = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            source = try? WorkspaceMailbox(workspace: loginHome, path: accountPath)
            let root = AgentStorageLayout(workspace: workspace).package.deletingLastPathComponent().deletingLastPathComponent()
            copies = try WorkspaceMailbox(workspace: root, path: "HarnessLogins/" + key, create: true)
        }

        func holds(_ name: String, runtime: WorkspaceMailbox) -> Bool {
            guard let stamp = try? runtime.read(stamp(name), limit: 256) else { return false }
            return String(decoding: stamp, as: UTF8.self).hasPrefix(key + ":")
        }

        /// False when there is no login to share. `writeBack` takes a bot's refresh
        /// of a Keychain login to the item and returns what the item now holds.
        func exchange(_ name: String, from origin: Origin, destination: WorkspaceMailbox, runtime: WorkspaceMailbox,
                      writeBack: ((Data) throws -> Data?)? = nil) throws -> Bool {
            var result = false
            try copies.withLock(".lock", wait: true) {
                let store: WorkspaceMailbox?
                switch origin {
                case .file: store = source
                case .unknown: store = copies.contains(name) ? copies : source
                case .item(let login):
                    // A new sign-in, or the harness refreshing its own item, replaces the shared copy.
                    if (try? copies.read(name + ".origin", limit: 256)) != tag(login) {
                        try copies.writeData(login, named: name)
                        try copies.writeData(tag(login), named: name + ".origin")
                    }
                    store = copies
                }
                let shared = store.flatMap { $0.contains(name) ? try? $0.read(name, limit: 1_048_576) : nil }
                let agreed = try? runtime.read(stamp(name), limit: 256)
                let copy = destination.contains(name) ? try destination.read(name, limit: 1_048_576) : nil
                if let store, let shared, let copy, agreed != tag(copy), agreed == tag(shared) {
                    // This bot refreshed the login since it last took it.
                    try store.writeData(copy, named: name)
                    try runtime.writeData(tag(copy), named: stamp(name))
                    if case .item = origin, let written = try? writeBack?(copy) {
                        try copies.writeData(tag(written), named: name + ".origin")
                    }
                    result = true
                    return
                }
                guard let shared else { return }
                if copy != shared { try destination.writeData(shared, named: name) }
                if agreed != tag(shared) { try runtime.writeData(tag(shared), named: stamp(name)) }
                result = true
            }
            return result
        }

        /// The login `exchange` would leave the bot holding, without exchanging anything.
        func next(_ name: String, from origin: Origin, destination: WorkspaceMailbox?, runtime: WorkspaceMailbox) -> Data? {
            let store: WorkspaceMailbox?
            switch origin {
            case .file: store = source
            case .unknown: store = copies.contains(name) ? copies : source
            case .item(let login):
                if (try? copies.read(name + ".origin", limit: 256)) != tag(login) { return login }
                store = copies
            }
            let shared = store.flatMap { $0.contains(name) ? try? $0.read(name, limit: 1_048_576) : nil }
            let agreed = try? runtime.read(stamp(name), limit: 256)
            let copy = destination.flatMap { $0.contains(name) ? try? $0.read(name, limit: 1_048_576) : nil }
            if let shared, let copy, agreed != tag(copy), agreed == tag(shared) { return copy }
            return shared
        }

        func tag(_ data: Data) -> Data {
            Data((key + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()).utf8)
        }

        private func stamp(_ name: String) -> String { Self.stamp(provider, name) }

        static func stamp(_ provider: HarnessProvider, _ name: String) -> String { "auth-seed-\(provider.rawValue)-\(name).sha256" }
    }

    private static func missing(_ provider: HarnessProvider) -> HarnessSetupError {
        HarnessSetupError("The \(provider.displayName) login is unavailable for this bot's private storage. Sign in to the harness, then retry startup.")
    }

    public static func readSecret(service: String, account: String) throws -> Data? {
        try readSecret(service: service, account: account, tool: securityTool)
    }

    static func readSecret(service: String, account: String,
                           tool: ([String]) throws -> (status: Int32, output: Data)) throws -> Data? {
        // Claude Code and Antigravity write their items with /usr/bin/security,
        // which leaves only that tool trusted. FX recreates its items on token
        // refresh, which drops Always Allow. A direct read would ask for the
        // login password each time.
        // A Claude Code profile's item carries its folder's digest after the name.
        guard ["Claude Code-credentials", "gemini", "FX_OAUTH_SESSION_V1", "FX_AI_GATEWAY_API_KEY"].contains(service)
                || service.hasPrefix("Claude Code-credentials-") else {
            return try readKeychainItem(service: service, account: account)
        }
        let result = try tool(["find-generic-password", "-s", service, "-a", account, "-w"])
        if result.status == 44 { return nil }
        var text = String(decoding: result.output, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        guard result.status == 0, !text.isEmpty, result.output.count <= 2_097_152 else {
            throw HarnessSetupError("macOS did not allow Noodle Agent Host to read the harness login (\(result.status)). Unlock the login keychain, then retry startup.")
        }
        // The tool prints hex when the stored bytes are not plain text.
        if text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) {
            var bytes = Data(), index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                bytes.append(UInt8(text[index..<next], radix: 16)!)
                index = next
            }
            return bytes
        }
        return Data(text.utf8)
    }

    /// Writes a Claude Code login item the way the CLI does, through the tool it
    /// trusts. The command goes in on standard input, so the login never shows
    /// in the process list.
    public static func writeSecret(service: String, account: String, data: Data) throws {
        guard service == "Claude Code-credentials" || service.hasPrefix("Claude Code-credentials-"),
              !account.contains("\""), !account.contains("\n") else { throw HarnessSetupError("Unsupported harness login item.") }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data("add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HarnessSetupError("macOS did not allow Noodle Agent Host to update the harness login (\(process.terminationStatus)).")
        }
    }

    private static func securityTool(_ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private static func readKeychainItem(service: String, account: String) throws -> Data? {
        // Exact provider item only. Never enumerate Keychain or permit a prompt
        // during background startup. Access denial leaves the sandbox closed.
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, data.count <= 1_048_576 else {
            throw HarnessSetupError("macOS did not allow Noodle Agent Host to read the harness login (\(status)). Grant that helper access to the provider's login item in Keychain Access, then retry startup.")
        }
        return data
    }
}
