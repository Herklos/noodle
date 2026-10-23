import Foundation
import Observation
import NoodleCore

/// The harnesses this Mac offers. One turned off is left out of Settings and every
/// harness picker, is not probed, and its bots do not start.
@MainActor @Observable
public final class HarnessSelection {
    static let defaultsKey = "Noodle.harness.turnedOn"
    static let fallbackDefaultsKey = "Noodle.harness.fallback"
    static let fallbacksDefaultsKey = "Noodle.harness.fallbacks"

    @ObservationIgnored private let defaults: UserDefaults?
    /// The person's own choices; a harness without one keeps its default.
    private var choices: [String: Bool]
    /// Whether a bot whose harness runs out of usage continues on another one. Off until the person turns it on.
    public private(set) var fallbackIsOn: Bool
    /// Where such a bot continues, in order. Kept while fallback is off, so turning it on again restores it.
    public private(set) var fallbacks: [HarnessProvider]

    /// Everything on and nothing saved, for runtimes no person chooses for.
    public init() {
        defaults = nil
        choices = Dictionary(uniqueKeysWithValues: HarnessProvider.allCases.map { ($0.rawValue, true) })
        fallbackIsOn = false
        fallbacks = []
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        choices = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Bool] ?? [:]
        fallbackIsOn = defaults.bool(forKey: Self.fallbackDefaultsKey)
        fallbacks = Self.unique((defaults.stringArray(forKey: Self.fallbacksDefaultsKey) ?? []).compactMap(HarnessProvider.init(rawValue:)))
    }

    public func isOn(_ provider: HarnessProvider) -> Bool { choices[provider.rawValue] ?? provider.isOnByDefault }

    public func set(_ provider: HarnessProvider, on: Bool) {
        guard isOn(provider) != on else { return }
        choices[provider.rawValue] = on
        defaults?.set(choices, forKey: Self.defaultsKey)
    }

    public func setFallback(on: Bool) {
        guard fallbackIsOn != on else { return }
        fallbackIsOn = on
        defaults?.set(on, forKey: Self.fallbackDefaultsKey)
    }

    public func setFallbacks(_ providers: [HarnessProvider]) {
        let providers = Self.unique(providers)
        guard fallbacks != providers else { return }
        fallbacks = providers
        defaults?.set(providers.map(\.rawValue), forKey: Self.fallbacksDefaultsKey)
    }

    private static func unique(_ providers: [HarnessProvider]) -> [HarnessProvider] {
        var seen: Set<HarnessProvider> = []
        return providers.filter { seen.insert($0).inserted }
    }
}
