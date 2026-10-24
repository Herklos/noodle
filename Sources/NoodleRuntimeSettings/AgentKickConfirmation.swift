import SwiftUI
import NoodleCore
import NoodleRuntime

/// Attach to the containing view so closing a context menu cannot dismiss the alert.
/// Every button ends the request itself, and an answered request never presents again,
/// so no button can bring the alert back.
public struct AgentKickConfirmation: ViewModifier {
    let store: any BotSettingsHost
    @Environment(\.openSettings) private var openSettings
    @Binding var request: AgentKickRequest?
    @State private var answered: UUID?

    public func body(content: Content) -> some View {
        content.alert(request?.title ?? "Recover Bot", isPresented: Binding(
            get: { request.map { $0.id != answered } ?? false }, set: { if !$0 { answer() } }
        ), presenting: request) { request in
            if request.failure == .authenticationRequired {
                Button("Open Harness Settings") {
                    answer()
                    store.showHarnessSettings()
                    openSettings()
                }
            }
            Button(request.confirmTitle) {
                answer()
                store.runtime.confirmKick(request, repository: store.repository)
            }
            if request.offersNewSession {
                Button("New Session") {
                    answer()
                    store.runtime.startNewSession(agent: request.agent, repository: store.repository)
                }
            }
            Button("Cancel", role: .cancel) { answer() }
        } message: { request in
            Text(request.message)
        }
    }

    private func answer() {
        answered = request?.id ?? answered
        request = nil
    }

    public init(store: any BotSettingsHost, request: Binding<AgentKickRequest?>) {
        self.store = store
        self._request = request
    }
}
