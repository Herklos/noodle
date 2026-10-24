import BrowserBridge
import Foundation

/// Tabs bots opened and then left unused. Each bot is told once per idle stretch, in one note
/// listing all of its tabs, so it can close the ones it no longer needs. Tabs a person opened are
/// never reported; the days-long expiry closes whatever is left.
struct BrowserIdleWatch {
    static let unused: TimeInterval = 6 * 60 * 60
    struct Tab { var browser: String; var browserID: UUID; var info: BrowserTabInfo }
    /// The last use each reported tab had when it was reported; a later use starts a new stretch.
    private var reported: [UUID: Date] = [:]

    /// `tabs` are the caller's tabs that nothing on screen, no live viewer and no dialog is using.
    mutating func due(_ tabs: [Tab], at now: Date) -> [BrowserIdleNotice] {
        var byBot: [(agent: UUID, tabs: [Tab])] = []
        for tab in tabs {
            guard let agent = tab.info.openedBy, let used = tab.info.lastUsed, now.timeIntervalSince(used) >= Self.unused,
                  reported[tab.info.id] != used else { continue }
            reported[tab.info.id] = used
            if let index = byBot.firstIndex(where: { $0.agent == agent }) { byBot[index].tabs.append(tab) }
            else { byBot.append((agent, [tab])) }
        }
        return byBot.map { agent, tabs in
            let lines = tabs.map { tab in
                let hours = Int(now.timeIntervalSince(tab.info.lastUsed ?? now) / 3600)
                return "- “\(tab.info.title)” \(tab.info.url), unused for \(hours) hours (browser \(tab.browser) \(tab.browserID.uuidString), tab \(tab.info.id.uuidString))"
            }
            let note = "Browser tabs you opened have not been used for \(Int(Self.unused / 3600)) hours or more:\n"
                + lines.joined(separator: "\n")
                + "\nIf you no longer need them, close them (close)."
            return BrowserIdleNotice(agentID: agent, tabIDs: tabs.map(\.info.id), note: note)
        }
    }
    /// Forgets tabs that were closed.
    mutating func keep(_ tabs: Set<UUID>) { reported = reported.filter { tabs.contains($0.key) } }
}
