import SwiftUI
import NoodleCore
import NoodleRuntime

/// Settings › Harnesses: where every bot continues, in order, when its harness runs out of usage.
struct HarnessFallbackSection: View {
    let runtime: AgentRuntimeCoordinator

    private var harnesses: HarnessSelection { runtime.harnesses }

    /// Harnesses turned on and not in the list yet.
    private var addable: [HarnessProvider] {
        HarnessProvider.allCases.filter { harnesses.isOn($0) && !harnesses.fallbacks.contains($0) }
    }

    var body: some View {
        Section {
            Toggle("Continue on another harness when one runs out of usage", isOn: Binding(
                get: { harnesses.fallbackIsOn }, set: { harnesses.setFallback(on: $0) }))
                .help("A bot whose harness runs out of usage continues on the next harness in this list that is on, installed and has usage left, with that harness’s default model. It goes back once its own harness has usage again.")
            if harnesses.fallbackIsOn {
                ForEach(Array(harnesses.fallbacks.enumerated()), id: \.element) { index, provider in
                    row(provider, at: index)
                }
                HStack {
                    Menu("Add Harness") {
                        ForEach(addable, id: \.self) { provider in
                            Button(provider.displayName) { harnesses.setFallbacks(harnesses.fallbacks + [provider]) }
                        }
                    }
                    .fixedSize()
                    .disabled(addable.isEmpty)
                    Spacer()
                }
            }
        }
    }

    private func row(_ provider: HarnessProvider, at index: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
            Text(provider.displayName)
            Spacer(minLength: 8)
            status(provider)
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("Move Up") { move(index, by: -1) }
                    .disabled(index == 0)
                Button("Move Down") { move(index, by: 1) }
                    .disabled(index == harnesses.fallbacks.count - 1)
                Divider()
                Button("Remove", role: .destructive) {
                    harnesses.setFallbacks(harnesses.fallbacks.filter { $0 != provider })
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(provider.displayName) Actions")
        }
    }

    @ViewBuilder private func status(_ provider: HarnessProvider) -> some View {
        if !harnesses.isOn(provider) {
            Text("Turned off")
        } else if !runtime.installations.contains(where: { $0.provider == provider && $0.isAvailable }) {
            Text("Not installed")
        } else if let date = runtime.usageReturns(provider) {
            Text("Out of usage until \(date, format: Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())")
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var list = harnesses.fallbacks
        guard list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        harnesses.setFallbacks(list)
    }
}
