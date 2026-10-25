import Foundation
import NoodleCore

public enum FxSetupProvider {
    public static let installationGuide = HarnessInstallationGuide(command: "curl -fsSL https://fx.sh/setup.sh | bash",
        instructions: "Run Vercel’s official FX installer in Terminal, then check the installation here and sign in with Vercel. Noodle keeps its own sign-in, separate from the one fx uses in Terminal.",
        documentationURL: URL(string: "https://fx.sh/docs")!)
}

@MainActor
public enum FxModelProbe {
    /// Codex only when the app cannot run it itself: a copy Noodle installed.
    static func load(path: String, provider: HarnessProvider = .fx) async throws -> [HarnessModel] {
        try await AgentHostRequest().load(timeout: .seconds(65), noReply: "\(provider.displayName) returned no models.",
            timedOut: "\(provider.displayName) model discovery timed out.") {
            if provider == .codex { $0.codexModels(executablePath: path, reply: $1) }
            else { $0.fxModels(executablePath: path, reply: $1) }
        }
    }
}
