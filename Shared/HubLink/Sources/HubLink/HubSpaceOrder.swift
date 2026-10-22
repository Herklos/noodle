import Foundation

/// The order the person put their joined Hubs' spaces in, after All, by Hub key. Kept on this device only: Hubs
/// are joined per device, and a new iCloud record type is more than an order is worth.
public struct HubSpaceOrder: Equatable, Sendable {
    /// Where the order is kept in the app's user defaults.
    public static let key = "HubSpaceOrder"

    /// Hub keys, first shown first. A Hub that was left keeps its place for when it is joined again.
    public private(set) var keys: [String]

    public init(keys: [String] = []) { self.keys = keys }

    /// As kept: one Hub key per line. Hub keys are base64, so never hold a line break.
    public init(stored: String) { keys = stored.split(separator: "\n").map(String.init) }

    public var stored: String { keys.joined(separator: "\n") }

    /// The Hubs in the person's order; those not put in order yet, such as one just joined, follow as they came.
    public func sorted<Hub>(_ hubs: [Hub], key: (Hub) -> String) -> [Hub] {
        let rank = Dictionary(keys.enumerated().map { ($1, $0) }) { first, _ in first }
        return hubs.enumerated().sorted { lhs, rhs in
            switch (rank[key(lhs.element)], rank[key(rhs.element)]) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// As a list's drag hands it over, for the Hubs shown in that order.
    public mutating func move(_ shown: [String], fromOffsets source: IndexSet, toOffset destination: Int) {
        var moved = shown
        moved.move(fromOffsets: source, toOffset: destination)
        keys = moved + keys.filter { !moved.contains($0) }
    }
}
