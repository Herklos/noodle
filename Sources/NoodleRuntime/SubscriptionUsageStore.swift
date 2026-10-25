import Foundation
import NoodleCore
import Observation

/// The latest plan limits of each signed-in account, for Settings. Readings come
/// from the bots' own turns and from the account check Settings runs when it
/// opens; nothing is polled. Only the last reading per account is kept, so
/// Settings has something to show after Noodle restarts.
@MainActor @Observable
public final class SubscriptionUsageStore {
    public static let defaultsKey = "Noodle.subscriptionUsage.v1"
    public private(set) var accounts: [String: SubscriptionUsage]
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accounts = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: SubscriptionUsage].self, from: $0) } ?? [:]
    }

    /// A harness's default login, or one of its profiles.
    public static func key(_ provider: HarnessProvider, profile: UUID?) -> String {
        profile.map { "\(provider.rawValue)/\($0.uuidString)" } ?? provider.rawValue
    }

    public func usage(_ provider: HarnessProvider, profile: UUID?) -> SubscriptionUsage? {
        accounts[Self.key(provider, profile: profile)]
    }

    public func record(_ usage: SubscriptionUsage, provider: HarnessProvider, profile: UUID?) {
        let key = Self.key(provider, profile: profile)
        // A reading that arrives late must not replace a newer one.
        if let current = accounts[key], current.updatedAt > usage.updatedAt { return }
        guard accounts[key] != usage else { return }
        accounts[key] = usage
        save()
    }

    /// Takes the plan limits a bot's harness sent during its turn, if the message has any.
    public func record(_ message: [String: Any], provider: HarnessProvider, profile: UUID?, at date: Date) {
        guard let usage = SubscriptionUsage.reading(message, provider: provider,
                                                    previous: self.usage(provider, profile: profile), at: date) else { return }
        record(usage, provider: provider, profile: profile)
    }

    /// A deleted profile's account is gone with it.
    public func forget(_ provider: HarnessProvider, profile: UUID) {
        guard accounts.removeValue(forKey: Self.key(provider, profile: profile)) != nil else { return }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
