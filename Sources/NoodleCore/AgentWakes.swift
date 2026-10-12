import Darwin
import Foundation

/// A wake a bot scheduled for itself through Messenger, with a note to its future self.
public struct AgentWake: Codable, Hashable, Sendable {
    public let id: UUID
    public let dueAt: Date
    public let note: String

    public init(id: UUID = UUID(), dueAt: Date, note: String) {
        self.id = id; self.dueAt = dueAt; self.note = note
    }
}

/// What `--list-wakes` returns. `due` holds wakes that fired since the bot last listed them.
public struct AgentWakeList: Codable, Hashable, Sendable {
    public let due: [AgentWake]
    public let pending: [AgentWake]
}

/// Limits that keep a bot waking itself from turning into a loop.
public enum AgentWakeLimits {
    public static let pending = 3
    public static let minimumDelay: TimeInterval = 300
    /// Wakes in a row with no message from anyone else in the bot's conversations.
    public static let withoutOutsideMessages = 12
    public static let noteLength = 1_000
}

struct AgentWakeError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

/// Kept in the bot's package beside agent.json, outside the workspace, so the bot can change
/// it only through Messenger and its limits. It moves with the bot to a Hub.
private struct AgentWakeState: Codable {
    var pending: [AgentWake] = []
    var due: [AgentWake] = []
    /// When the bot's wakes fired, counted against `withoutOutsideMessages`.
    var fired: [Date] = []
}

extension WorkspaceRepository {
    public func scheduleWake(agentID: UUID, at dueAt: Date, note rawNote: String, now: Date = Date()) throws -> AgentWake {
        let note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty, note.count <= AgentWakeLimits.noteLength else {
            throw AgentWakeError("A wake needs a --note of at most \(AgentWakeLimits.noteLength) characters saying what to do when it fires.")
        }
        guard dueAt.timeIntervalSince(now) >= AgentWakeLimits.minimumDelay else {
            throw AgentWakeError("A wake must be at least \(Int(AgentWakeLimits.minimumDelay / 60)) minutes ahead. To keep working now, just continue.")
        }
        let lastOutside = try lastOutsideMessageDate(agentID: agentID)
        return try updateWakes(agentID: agentID) { state in
            if let lastOutside { state.fired.removeAll { $0 <= lastOutside } }
            guard state.pending.count < AgentWakeLimits.pending else {
                throw AgentWakeError("You already have \(AgentWakeLimits.pending) wakes scheduled. Cancel one with --cancel-wake first.")
            }
            guard state.fired.count + state.pending.count < AgentWakeLimits.withoutOutsideMessages else {
                throw AgentWakeError("You have woken yourself \(AgentWakeLimits.withoutOutsideMessages) times with no message from anyone else. Wait for a message before scheduling more wakes, or ask for what you need.")
            }
            // Whole seconds, as stored, so the wake returned now equals the one listed later.
            let wake = AgentWake(dueAt: Date(timeIntervalSince1970: dueAt.timeIntervalSince1970.rounded(.up)), note: note)
            state.pending.append(wake)
            state.pending.sort { $0.dueAt < $1.dueAt }
            return wake
        }
    }

    /// Hands over the wakes that fired; they are not listed again.
    public func listWakes(agentID: UUID) throws -> AgentWakeList {
        try updateWakes(agentID: agentID) { state in
            defer { state.due = [] }
            return AgentWakeList(due: state.due, pending: state.pending)
        }
    }

    public func cancelWake(agentID: UUID, id: UUID) throws -> AgentWake {
        try updateWakes(agentID: agentID) { state in
            guard let index = state.pending.firstIndex(where: { $0.id == id }) else {
                throw AgentWakeError("No scheduled wake has that ID. Use --list-wakes to see your wakes.")
            }
            return state.pending.remove(at: index)
        }
    }

    public func nextWakeDate(agentID: UUID) -> Date? {
        (try? readWakes(agentID: agentID))?.pending.first?.dueAt
    }

    /// Moves wakes that are due to the ones the bot is shown. Returns whether any were due.
    public func takeDueWakes(agentID: UUID, at now: Date) throws -> Bool {
        try updateWakes(agentID: agentID) { state in
            let due = state.pending.filter { $0.dueAt <= now }
            guard !due.isEmpty else { return false }
            state.pending.removeAll { $0.dueAt <= now }
            state.due += due
            state.fired.append(now)
            return true
        }
    }

    private func wakesURL(agentID: UUID) -> URL { storage(for: agentID).package.appendingPathComponent("wakes.json") }

    private func readWakes(agentID: UUID) throws -> AgentWakeState {
        let url = wakesURL(agentID: agentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return AgentWakeState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentWakeState.self, from: Data(contentsOf: url))
    }

    /// Messenger and the runtime change the file from different threads, so changes take a lock.
    private func updateWakes<Value>(agentID: UUID, _ change: (inout AgentWakeState) throws -> Value) throws -> Value {
        let package = storage(for: agentID).package
        guard FileManager.default.fileExists(atPath: package.path) else { throw WorkspaceError.missingAgent(agentID) }
        let descriptor = Darwin.open(package.appendingPathComponent(".wakes.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        var state = try readWakes(agentID: agentID)
        let original = state
        let value = try change(&state)
        if state.pending != original.pending || state.due != original.due || state.fired != original.fired {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(encoder.encode(state), to: wakesURL(agentID: agentID))
        }
        return value
    }

    private func lastOutsideMessageDate(agentID: UUID) throws -> Date? {
        try loadConversations().filter { $0.participantIDs.contains(agentID) }.compactMap { conversation in
            try loadMessages(conversationID: conversation.id).last { $0.author != .agent(agentID) }?.createdAt
        }.max()
    }
}
