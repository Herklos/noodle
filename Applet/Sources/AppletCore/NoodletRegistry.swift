import Foundation

/// Link identity is independent of a running session and never written into authored packages.
public final class NoodletRegistry {
    private struct Entry: Codable {
        var id: UUID
        var path: String
        var bookmark: Data
    }
    private let file: URL
    private var entries: [Entry]

    public init(file: URL) throws {
        self.file = file
        entries = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file)) : []
    }

    public func id(for package: URL) throws -> UUID {
        let url = package.resolvingSymlinksInPath().standardizedFileURL
        // Check every stored path before resolving bookmarks. Resolving earlier
        // entries for each known package made library scans quadratic in costly
        // bookmark lookups, even when nothing in the library had changed.
        if let entry = entries.first(where: { $0.path == url.path }) { return entry.id }
        let index = entries.firstIndex { resolved($0) == url }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let entry = Entry(id: index.map { entries[$0].id } ?? UUID(), path: url.path, bookmark: bookmark)
        let previous = entries
        if let index { entries[index] = entry } else { entries.append(entry) }
        do { try persist() } catch { entries = previous; throw error }
        return entry.id
    }

    /// Points the link of the package at `from` to the one at `to`, so links already shared open it.
    public func move(_ from: URL, to: URL) throws {
        let old = from.resolvingSymlinksInPath().standardizedFileURL.path
        guard let index = entries.firstIndex(where: { $0.path == old }) else { return }
        let url = to.resolvingSymlinksInPath().standardizedFileURL
        let previous = entries
        entries[index] = Entry(id: entries[index].id, path: url.path,
                               bookmark: try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        do { try persist() } catch { entries = previous; throw error }
    }

    /// Every linked package where it is now: its stored path while that exists, else where its
    /// bookmark leads, in which case the link follows it there. A package found nowhere is forgotten.
    public func packages() -> [URL] {
        var found: [URL] = [], changed = false
        entries = entries.filter { entry in
            if FileManager.default.fileExists(atPath: entry.path) {
                found.append(URL(fileURLWithPath: entry.path))
                return true
            }
            changed = true
            return false
        } + entries.compactMap { entry -> Entry? in
            guard !FileManager.default.fileExists(atPath: entry.path), let url = resolved(entry),
                  let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            else { return nil }
            found.append(url)
            return Entry(id: entry.id, path: url.path, bookmark: bookmark)
        }
        if changed { try? persist() }
        return found
    }

    /// Forgets the link of the package at `package`; links already shared to it stop opening it.
    public func forget(_ package: URL) throws {
        let path = package.resolvingSymlinksInPath().standardizedFileURL.path
        guard entries.contains(where: { $0.path == path }) else { return }
        let previous = entries
        entries.removeAll { $0.path == path }
        do { try persist() } catch { entries = previous; throw error }
    }

    public func resolve(_ id: UUID) -> URL? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        return resolved(entry)
    }

    private func resolved(_ entry: Entry) -> URL? {
        var stale = false
        let bookmarked = try? URL(resolvingBookmarkData: entry.bookmark,
            options: [.withoutUI], bookmarkDataIsStale: &stale)
        for candidate in [bookmarked, URL(fileURLWithPath: entry.path)].compactMap({ $0 }) {
            let url = candidate.resolvingSymlinksInPath().standardizedFileURL
            if !url.pathComponents.contains(".Trash"), !url.pathComponents.contains(".Trashes"),
               (try? url.checkResourceIsReachable()) == true { return url }
        }
        return nil
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
