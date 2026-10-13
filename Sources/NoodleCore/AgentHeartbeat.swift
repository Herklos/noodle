import Foundation

public struct AgentHeartbeatConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let intervalMinutes: Int
    public let disabledAgentIDs: Set<UUID>

    public init(isEnabled: Bool = true, intervalMinutes: Int = 30, disabledAgentIDs: Set<UUID> = []) {
        self.isEnabled = isEnabled
        self.intervalMinutes = min(1_440, max(1, intervalMinutes))
        self.disabledAgentIDs = disabledAgentIDs
    }

    public var interval: TimeInterval { TimeInterval(intervalMinutes) * 60 }

    public func isEnabled(for agentID: UUID) -> Bool {
        isEnabled && !disabledAgentIDs.contains(agentID)
    }

    public static func load(from defaults: UserDefaults) -> Self {
        Self(
            isEnabled: defaults.object(forKey: "Noodle.heartbeat.enabled") as? Bool ?? true,
            intervalMinutes: defaults.object(forKey: "Noodle.heartbeat.minutes") as? Int ?? 30,
            disabledAgentIDs: Set((defaults.stringArray(forKey: "Noodle.heartbeat.disabledAgents") ?? [])
                .compactMap(UUID.init(uuidString:)))
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: "Noodle.heartbeat.enabled")
        defaults.set(intervalMinutes, forKey: "Noodle.heartbeat.minutes")
        defaults.set(disabledAgentIDs.map(\.uuidString).sorted(), forKey: "Noodle.heartbeat.disabledAgents")
    }
}

/// A clock-injected inactivity policy. Checking the deadline never counts as activity.
/// One overdue heartbeat is consumed, even after a long sleep; there is no catch-up burst.
public struct AgentHeartbeatScheduler: Sendable {
    public private(set) var configuration: AgentHeartbeatConfiguration
    public private(set) var lastActivity: [UUID: Date] = [:]

    public init(
        configuration: AgentHeartbeatConfiguration = .init(),
        lastActivity: [UUID: Date] = [:]
    ) {
        self.configuration = configuration
        self.lastActivity = lastActivity
    }

    /// Begin tracking a bot without treating process startup as new activity.
    /// Existing persisted activity always wins.
    @discardableResult
    public mutating func register(_ agentID: UUID, at date: Date) -> Bool {
        guard lastActivity[agentID] == nil else { return false }
        lastActivity[agentID] = date
        return true
    }

    public mutating func recordActivity(for agentID: UUID, at date: Date) {
        lastActivity[agentID] = date
    }

    public mutating func remove(_ agentID: UUID) { lastActivity.removeValue(forKey: agentID) }

    public mutating func configure(_ updated: AgentHeartbeatConfiguration, at date: Date) {
        guard configuration != updated else { return }
        if configuration.isEnabled != updated.isEnabled || configuration.intervalMinutes != updated.intervalMinutes {
            lastActivity = lastActivity.mapValues { _ in date }
        } else {
            for id in configuration.disabledAgentIDs.symmetricDifference(updated.disabledAgentIDs)
                where lastActivity[id] != nil {
                lastActivity[id] = date
            }
        }
        configuration = updated
    }

    public mutating func takeDueHeartbeats(readyAgentIDs: Set<UUID>, at date: Date) -> [UUID] {
        let due = readyAgentIDs.filter { id in
            guard configuration.isEnabled(for: id), let last = lastActivity[id] else { return false }
            return date.timeIntervalSince(last) >= configuration.interval
        }.sorted { $0.uuidString < $1.uuidString }
        for id in due { lastActivity[id] = date }
        return due
    }
}

public enum AgentWakeReason: String, CaseIterable, Sendable {
    case inboxChanged = "inbox-changed"
    case heartbeat
    /// A wake the bot scheduled for itself.
    case wake
    case runtimeRecovered = "runtime-recovered"
    /// The person asked the bot to tidy its own workspace files.
    case organize

    /// Turns Noodle starts on a timer rather than for a message; they do not count as interaction.
    public var isScheduled: Bool { self == .heartbeat || self == .wake }

    /// Names the Messenger skill so a bot whose harness never surfaced it still knows where to look.
    /// A bot reads the skill once a session, and a long session of quiet heartbeats drifts into
    /// only checking the inbox, so every heartbeat names the work itself.
    public var eventText: String {
        let event = "<noodle-event type=\"\(rawValue)\" skill=\".agents/skills/messenger/SKILL.md\" />"
        guard self == .heartbeat else { return event }
        return event + "\nCheck Messenger once, then do the next full round of each assignment in assignments.md."
    }

    /// What the bot's activity shows while the turn runs.
    public var activityDetail: String {
        switch self {
        case .heartbeat: "Heartbeat: checking for follow-up work"
        case .wake: "Waking as scheduled"
        case .runtimeRecovered: "Recovering interrupted work"
        case .inboxChanged: "Checking for new messages"
        case .organize: "Organizing workspace files"
        }
    }

    public static var heartbeatInstructions: String { AgentWakeReason.heartbeat.reference.guidance }

    public static var recoveryInstructions: String { AgentWakeReason.runtimeRecovered.reference.guidance }
}
