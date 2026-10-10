import Darwin
import Foundation

/// Releasing a background session ends it without a logout, so macOS keeps its login
/// open: `who` and `last` show the account signed in until the next one. Stop records
/// the logout itself once the session is gone.
public enum LocalMacLoginRecords {
    /// Ends each login still open for `user`, returning how many. `database` replaces the
    /// system's for tests.
    @discardableResult
    public static func close(user: String, at now: Date = Date(), database: String? = nil) -> Int {
        if let database { _ = utmpxname(database) }
        defer { if database != nil { _ = utmpxname(nil) } }
        var open: [utmpx] = []
        setutxent()
        while let entry = getutxent() {
            var record = entry.pointee
            guard record.ut_type == Int16(USER_PROCESS),
                  withUnsafeBytes(of: &record.ut_user, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == user else { continue }
            open.append(record)
        }
        let seconds = now.timeIntervalSince1970.rounded(.down)
        var closed = 0
        for var record in open {
            // The same ut_id replaces the login with its end, as a logout would.
            record.ut_type = Int16(DEAD_PROCESS)
            record.ut_tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((now.timeIntervalSince1970 - seconds) * 1_000_000))
            setutxent()
            if pututxline(&record) != nil { closed += 1 }
        }
        endutxent()
        return closed
    }
}
