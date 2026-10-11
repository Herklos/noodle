import Foundation
import Observation
import NoodleCore

/// The harnesses this Mac offers. One turned off is left out of Settings and every
/// harness picker, is not probed, and its bots do not start.
@MainActor @Observable
public final class HarnessSelection {
    static let defaultsKey = "Noodle.harness.turnedOn"

    @ObservationIgnored private let defaults: UserDefaults?
    /// The person's own choices; a harness without one keeps its default.
    private var choices: [String: Bool]

    /// Everything on and nothing saved, for runtimes no person chooses for.
    public init() {
        defaults = nil
        choices = Dictionary(uniqueKeysWithValues: HarnessProvider.allCases.map { ($0.rawValue, true) })
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        choices = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Bool] ?? [:]
    }

    public func isOn(_ provider: HarnessProvider) -> Bool { choices[provider.rawValue] ?? provider.isOnByDefault }

    public func set(_ provider: HarnessProvider, on: Bool) {
        guard isOn(provider) != on else { return }
        choices[provider.rawValue] = on
        defaults?.set(choices, forKey: Self.defaultsKey)
    }
}
