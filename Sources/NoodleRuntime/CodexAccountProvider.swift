import Foundation
import NoodleCore

/// Codex reports its account by being run. The app does that itself for a Codex
/// it can execute. A copy Noodle installed sits in the app's container, where
/// the sandbox refuses the app execute access, so the Agent Host runs it instead.
@MainActor
public final class CodexAccountProvider: HarnessSetupProviding {
    private let direct: CodexSetupProvider
    private let profile: UUID
    /// Makes the login's folder before it is first checked or signed in.
    private let prepare: () throws -> Void

    init(codexHome: URL, profile: UUID, prepare: @escaping () throws -> Void = {}) {
        direct = CodexSetupProvider(codexHome: codexHome)
        self.profile = profile
        self.prepare = prepare
    }

    public var installationGuide: HarnessInstallationGuide { direct.installationGuide }

    /// Receives the plan limits a sign-in check of a signed-in account reads, here or in the Agent Host.
    public var onUsage: (@MainActor (SubscriptionUsage) -> Void)? {
        get { direct.onUsage }
        set { direct.onUsage = newValue }
    }

    public func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        try prepare()
        guard let path = hostPath(installation) else { return try await direct.status(for: installation) }
        return try await HarnessAccountOperation().run(executablePath: path, signIn: false, provider: .codex, profile: profile,
                                                       onUsage: direct.onUsage)
    }

    public func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        try prepare()
        guard let path = hostPath(installation) else { return try await direct.signIn(for: installation, onChallenge: onChallenge) }
        return try await HarnessAccountOperation().run(executablePath: path, signIn: true, provider: .codex, profile: profile,
                                                       onChallenge: onChallenge)
    }

    private func hostPath(_ installation: HarnessInstallation) -> String? {
        guard installation.provider == .codex, let path = installation.executablePath,
              !FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
