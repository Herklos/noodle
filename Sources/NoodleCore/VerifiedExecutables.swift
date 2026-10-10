import Darwin
import Foundation

/// A full signature check reads and hashes the whole executable, hundreds of megabytes for some
/// harnesses, and the agent host checks on every inspection. A passed check is remembered for
/// the file as it was: replacing or editing it changes its identity, size or change time, and
/// it is checked in full again. A failure is never remembered.
enum VerifiedExecutables {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var passed: [String: [Int64]] = [:]

    static func verify(_ url: URL, requirement: String, check: () throws -> Void) throws {
        let key = url.path + "\n" + requirement
        // Taken before the check, so a change made while it runs is checked next time.
        let stamp = stamp(url.path)
        if let stamp, lock.withLock({ passed[key] }) == stamp { return }
        try check()
        if let stamp { lock.withLock { passed[key] = stamp } }
    }

    /// The link itself and the file it leads to, as the signature check opens it.
    private static func stamp(_ path: String) -> [Int64]? {
        var link = stat(), file = stat()
        guard lstat(path, &link) == 0, stat(path, &file) == 0 else { return nil }
        return [Int64(link.st_dev), Int64(bitPattern: link.st_ino), Int64(link.st_mode),
                Int64(file.st_dev), Int64(bitPattern: file.st_ino), Int64(file.st_mode), file.st_size,
                Int64(file.st_mtimespec.tv_sec), Int64(file.st_mtimespec.tv_nsec),
                Int64(file.st_ctimespec.tv_sec), Int64(file.st_ctimespec.tv_nsec)]
    }
}
