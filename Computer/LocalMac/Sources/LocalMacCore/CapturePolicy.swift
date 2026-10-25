import Foundation

/// Capture approval is independent of desktop resolution. The client supplies
/// its main-session display IDs; the account helper must reject every one.
public enum LocalMacCapturePolicy {
    public static func validateProtectedDisplays(_ ids: [UInt32]) throws {
        guard !ids.isEmpty, ids.count <= 32, !ids.contains(0), Set(ids).count == ids.count else {
            throw LocalMacError("Cannot verify the main desktop's displays before capture.")
        }
    }
    public static func validate(displayID: UInt32, isBuiltin: Bool, protectedIDs: [UInt32]) throws {
        try validateProtectedDisplays(protectedIDs)
        guard displayID != 0, !isBuiltin, !protectedIDs.contains(displayID) else {
            throw LocalMacError("Refused to capture a display belonging to the main desktop.")
        }
    }

    /// A display listed in the account session's shareable content.
    public struct SeenDisplay: Equatable, Sendable {
        public var id: UInt32
        public var isBuiltin: Bool
        public var width: Int
        public var height: Int
        public init(id: UInt32, isBuiltin: Bool, width: Int, height: Int) {
            self.id = id; self.isBuiltin = isBuiltin; self.width = width; self.height = height
        }
    }
    /// Reports what the account session saw when not exactly one display passes
    /// `validate`, so a failure says what macOS gave it. Never picks a display.
    public static func noSingleDisplay(_ seen: [SeenDisplay], protectedIDs: [UInt32]) -> (message: String, log: String) {
        let own = seen.filter { (try? validate(displayID: $0.id, isBuiltin: $0.isBuiltin, protectedIDs: protectedIDs)) != nil }
        let summary = own.count > 1 ? "This account has more than one display of its own, so none is shown."
            : "This account has no display of its own to show."
        let listed = seen.map { display in
            var notes = display.isBuiltin ? ["built-in"] : []
            notes.append("\(display.width) × \(display.height)")
            if protectedIDs.contains(display.id) { notes.append("main desktop") }
            return "\(display.id) (\(notes.joined(separator: ", ")))"
        }
        let detail = listed.isEmpty ? "It sees no displays." : "Displays it sees: \(listed.joined(separator: "; "))."
        let main = protectedIDs.map(String.init).joined(separator: ", ")
        return ("\(summary)\n\(detail)", "\(summary) \(detail) Main desktop displays: \(main).")
    }
}
