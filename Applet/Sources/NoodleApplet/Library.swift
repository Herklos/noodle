import AppKit
import AppletCore
import AppletBridge
import Foundation
import NoodleSettingsUI
import UniformTypeIdentifiers

struct LibraryEntry: Identifiable, Equatable {
  let id: String
  let package: NoodletPackage
  var title: String { package.manifest.title }
  private let previews: [PreviewStamp]

  init(package: NoodletPackage, thumbnails: URL) {
    self.package = package
    id = package.key
    previews = [thumbnails.appendingPathComponent("\(id).png"),
                package.url.appendingPathComponent("preview.png")].map(PreviewStamp.init)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.package.manifest == rhs.package.manifest && lhs.previews == rhs.previews
  }

  /// Capture metadata now; comparing live computed revisions would reread every
  /// package file and would compare both entries against the same current bytes.
  private struct PreviewStamp: Equatable {
    let modified: Date?
    let size: Int?
    init(_ url: URL) {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      modified = values?.contentModificationDate
      size = values?.fileSize
    }
  }
}

/// Where Noodle or Noodle Hub keeps its bots, each bot's own work in `<bot id>/workspace`.
/// Applet finds the noodlets bots make there itself and uses them where they are.
struct BotFolder: Equatable {
  let url: URL
  /// Noodle Hub's bots, whose noodlets are listed under Hub, apart from this Mac's own.
  let isHub: Bool

  /// Noodle's and Noodle Hub's, in their own containers, for this environment.
  static var system: [BotFolder] {
    // Applet is sandboxed too, so its own home is its container, not the user's.
    let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    let identity = AppletBuildIdentity.current
    return [(identity.noodleID, false), (identity.hubID, true)].map { app, hub in
      // Both keep their bots in Application Support/Noodle/Agents.
      BotFolder(url: URL(fileURLWithPath: home).appendingPathComponent(
        "Library/Containers/\(app)/Data/Library/Application Support/Noodle/Agents", isDirectory: true), isHub: hub)
    }
  }
}

/// Reports changes anywhere under a set of existing folders, on the main queue: the folders that
/// changed, or nil when FSEvents lost track and everything must be looked at again.
@MainActor private final class FolderWatch {
  private let changed: ([String]?) -> Void
  private var stream: FSEventStreamRef?
  private var paths: [String] = []

  init(changed: @escaping ([String]?) -> Void) { self.changed = changed }

  /// Watches `paths` instead of what it watched before, and says whether they differ; the same
  /// paths keep the stream running.
  @discardableResult func watch(_ paths: [String]) -> Bool {
    guard paths != self.paths else { return false }
    defer { self.paths = paths }
    stop()
    guard !paths.isEmpty else { return true }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    guard
      let stream = FSEventStreamCreate(
        nil,
        { _, info, count, paths, flags, _ in
          guard let info else { return }
          let folders = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]
          let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
          let rescan = (0..<count).contains { flags[$0] & lost != 0 }
          MainActor.assumeIsolated {
            Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue().changed(rescan ? nil : folders)
          }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
    else { return true }
    FSEventStreamSetDispatchQueue(stream, .main)
    FSEventStreamStart(stream)
    self.stream = stream
    return true
  }

  private func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}

/// Someone on Noodle Hub, as their bot's agent.json names them.
struct HubPerson: Hashable, Identifiable, Decodable {
  let id: UUID
  let name: String
}

@MainActor final class AppletLibrary: ObservableObject {
  let root: URL
  let documents: URL
  let botFolders: [BotFolder]
  @Published var entries: [LibraryEntry] = []
  @Published var error: String?
  @Published var recent: [String]
  @Published var pinned: [String]
  /// Kept in the library but listed only under Hidden, and Running while up: never in All, Recent, Pinned or the menu bar.
  @Published var hidden: [String]
  /// Made or opened by Noodle Hub's bots; listed only under Hub, apart from this Mac's own.
  @Published var hub: [String]
  /// Whose bot made each of Noodle Hub's noodlets, where the Hub names them.
  @Published private(set) var hubOwners: [String: HubPerson] = [:]
  private let defaults: UserDefaults
  private struct Registration {
    let url: URL
    let bookmark: Data
    let scoped: Bool
  }
  private var registrations: [Registration] = []
  private var timer: Timer?
  private var refreshing = false
  private var watch: FolderWatch?
  private var changed = false
  /// Bots' workspaces that changed since the last walk, walked on their own unless `changed`.
  private var changedWorkspaces: Set<URL> = []
  private var walked = Date()
  /// Finds the noodlets in places and bots' folders. Replaced in tests.
  var walk: @Sendable (_ places: [URL], _ botFolders: [URL], _ thumbnails: URL) -> Discovery = AppletLibrary.discover
  private var links: NoodletRegistry?
  /// Where noodlets keep their secrets, whichever device their page runs on.
  let secrets: AppletSecrets

  init(
    root: URL? = nil, defaults: UserDefaults = .standard, installExamples: Bool = true,
    watchChanges: Bool = true, botFolders: [BotFolder]? = nil, secrets: AppletSecrets = .shared
  ) {
    self.defaults = defaults
    self.secrets = secrets
    // A library kept elsewhere, as in a test, finds only the bots it is given.
    self.botFolders = botFolders ?? (root == nil ? BotFolder.system : [])
    self.root =
      root
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NoodleApplet")
    documents = self.root.appendingPathComponent("Noodlets")
    recent = defaults.stringArray(forKey: "recent") ?? []
    pinned = defaults.stringArray(forKey: "pinned") ?? []
    hidden = defaults.stringArray(forKey: "hidden") ?? []
    hub = defaults.stringArray(forKey: "hub") ?? []
    do {
      try FileManager.default.createDirectory(
        at: documents, withIntermediateDirectories: true)
      links = try NoodletRegistry(file: self.root.appendingPathComponent("NoodletLinks.json"))
      if installExamples, !defaults.bool(forKey: "examplesInstalled"),
        let source = AppletResources.bundle.url(
          forResource: "Resources", withExtension: nil)?.appendingPathComponent(
            "Examples")
      {
        for item
          in (try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == AppletBuildIdentity.current.fileExtension {
          let target = documents.appendingPathComponent(item.lastPathComponent)
          if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: item, to: target)
          }
        }
        defaults.set(true, forKey: "examplesInstalled")
      }
    } catch { self.error = error.localizedDescription }
    // Restore each opened package independently. A missing or damaged
    // bookmark must never prevent other creations from appearing.
    for data in defaults.array(forKey: "libraryBookmarks") as? [Data] ?? [] {
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
          bookmarkDataIsStale: &stale)
        let active = url.startAccessingSecurityScopedResource()
        if Self.missing(url)
          || registrations.contains(where: {
            Self.canonical($0.url) == Self.canonical(url)
          })
        {
          if active { url.stopAccessingSecurityScopedResource() }
          continue
        }
        let refreshed =
          stale
          ? try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil,
            relativeTo: nil) : nil
        registrations.append(
          Registration(url: url, bookmark: refreshed ?? data, scoped: active))
      } catch { continue }
    }
    persistRegistrations()
    scan()
    if watchChanges {
      watch = FolderWatch { [weak self] folders in
        if let folders { self?.foldersChanged(folders) } else { self?.foldersChanged() }
      }
      watch?.watch(watchedPaths())
      timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        Task { @MainActor in await self?.refreshIfChanged() }
      }
    }
  }
  /// The bot whose workspace holds `url`, by the name of its folder; nil for anything else.
  func owner(of url: URL) -> String? { bot(holding: url)?.owner }
  /// The name of the bot whose workspace holds `url`, as its agent.json gives it.
  func botName(of url: URL) -> String? {
    struct Configuration: Decodable { let displayName: String? }
    guard let bot = bot(holding: url),
      let data = try? Data(contentsOf: bot.folder.url.appendingPathComponent(bot.owner).appendingPathComponent("agent.json"))
    else { return nil }
    return (try? JSONDecoder().decode(Configuration.self, from: data))?.displayName
  }
  /// Whether `url` is in the workspace of one of Noodle Hub's bots.
  func isHub(_ url: URL) -> Bool { bot(holding: url)?.folder.isHub == true }
  private func bot(holding url: URL) -> (folder: BotFolder, owner: String)? {
    let parts = Self.canonical(url).pathComponents
    for folder in botFolders {
      let base = Self.canonical(folder.url).pathComponents
      guard parts.count > base.count + 2, Array(parts.prefix(base.count)) == base,
        parts[base.count + 1] == "workspace"
      else { continue }
      return (folder, parts[base.count])
    }
    return nil
  }
  nonisolated private static func canonical(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
  }
  private static func missing(_ url: URL) -> Bool {
    do { return !(try url.checkResourceIsReachable()) } catch {
      let error = error as NSError
      return
        (error.domain == NSCocoaErrorDomain
        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
        || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
  }
  private func persistRegistrations() {
    let bookmarks = registrations.map(\.bookmark)
    if bookmarks != defaults.array(forKey: "libraryBookmarks") as? [Data] {
      defaults.set(bookmarks, forKey: "libraryBookmarks")
    }
  }
  func scan() {
    changed = false
    changedWorkspaces = []
    walked = Date()
    let places = forget()
    apply(walk(places, botFolders.map(\.url), root.appendingPathComponent("Thumbnails", isDirectory: true)).entries)
  }
  /// What the watch timer runs. Walking bots' workspaces takes a tenth of a second or more, and
  /// recordings and live views capture on the main thread, so the walk happens off it.
  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    // Cleared before the walk: a change while it runs brings another.
    changed = false
    changedWorkspaces = []
    walked = Date()
    let places = forget(), folders = botFolders.map(\.url), walk = walk
    let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
    apply(await Task.detached { walk(places, folders, thumbnails) }.value.entries)
  }
  /// Something changed under a folder the library walks, so the next tick walks again.
  func foldersChanged() { changed = true }
  /// `paths` changed, so the next tick walks what they may have changed: nothing for a folder the
  /// walk never looks in, one bot's workspace for a change inside it, and everything otherwise.
  func foldersChanged(_ paths: [String]) {
    for path in paths {
      switch Self.change(at: path, botFolders: botFolders.map(\.url)) {
      case .none: continue
      case .workspace(let workspace): changedWorkspaces.insert(workspace)
      case .everything: changed = true
      }
    }
  }
  enum Change: Equatable {
    case none
    case workspace(URL)
    case everything
  }
  /// What a change in `path` may have changed for `discover`. Bots write all the time in hidden
  /// folders, deep in checkouts and in their own runtime files, where it never finds a noodlet.
  nonisolated static func change(at path: String, botFolders: [URL]) -> Change {
    let parts = canonical(URL(fileURLWithPath: path)).pathComponents
    for folder in botFolders {
      let base = canonical(folder).pathComponents
      guard parts.count >= base.count, Array(parts.prefix(base.count)) == base else { continue }
      let rest = Array(parts.dropFirst(base.count))
      // The folder itself, or a bot added or removed.
      guard rest.count >= 2 else { return .everything }
      guard rest[1] == "workspace" else { return .none }
      let inside = rest.dropFirst(2)
      let package = "." + AppletBuildIdentity.current.fileExtension
      // `discover` skips hidden items, and descends no further than four levels outside a package.
      if inside.contains(where: { $0.hasPrefix(".") }) { return .none }
      if inside.count > 4, !inside.contains(where: { $0.hasSuffix(package) }) { return .none }
      return .workspace(folder.appendingPathComponent(rest[0]).appendingPathComponent("workspace", isDirectory: true))
    }
    return .everything
  }
  /// What the watch timer runs: a walk only once something changed, and now and then anyway in
  /// case a change went unreported. Walking everything every two seconds cost a quarter of a core.
  func refreshIfChanged() async {
    if watch?.watch(watchedPaths()) == true { changed = true }
    if changed || Date().timeIntervalSince(walked) >= 60 {
      await refresh()
    } else if !changedWorkspaces.isEmpty {
      await refresh(workspaces: changedWorkspaces)
    }
  }
  /// Walks only `workspaces` and keeps what the library found everywhere else.
  private func refresh(workspaces: Set<URL>) async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    changedWorkspaces.subtract(workspaces)
    let places = Array(workspaces), walk = walk
    let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
    let found = await Task.detached { walk(places, [], thumbnails) }.value.entries
    let walked = workspaces.map { Self.canonical($0).pathComponents }
    var kept = [String: LibraryEntry]()
    for entry in entries {
      let parts = Self.canonical(entry.package.url).pathComponents
      guard !walked.contains(where: { parts.count > $0.count && Array(parts.prefix($0.count)) == $0 }) else { continue }
      kept[entry.id] = entry
    }
    apply(kept.merging(found) { _, new in new })
  }
  /// The folders the walk looks in that exist: FSEvents reports nothing under one made later,
  /// so the watch starts on it once it appears.
  private func watchedPaths() -> [String] {
    ([documents, root.appendingPathComponent("Thumbnails", isDirectory: true)]
      + registrations.map(\.url) + botFolders.map(\.url)).map(\.path)
      .filter { FileManager.default.fileExists(atPath: $0) }
  }
  /// Deletes what noodlets no longer anywhere Applet looks saved, as when one was deleted or moved
  /// outside Applet. Nothing goes when the walk could not look everywhere, nor for noodlets `inUse`.
  func removeOrphanedData(keeping inUse: () -> Set<String>) async {
    let places = forget(), folders = botFolders.map(\.url), walk = walk, root = root
    let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
    let found = await Task.detached { walk(places, folders, thumbnails) }.value
    apply(found.entries)
    guard found.complete else { return }
    let data = root.appendingPathComponent("Data")
    let saved = await Task.detached { (try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? [] }.value
    // Checked again before each one: a noodlet opened meanwhile keeps its data.
    for key in Set(saved).union(AppletStorage.stores(defaults: defaults).keys).sorted()
    where !entries.contains(where: { $0.id == key }) && !inUse().contains(key) {
      await AppletStorage.remove(key, root: root, defaults: defaults)
    }
  }
  /// Drops what was deleted and returns where to look for noodlets.
  private func forget() -> [URL] {
    let deleted = Set(entries.filter { Self.missing($0.package.url) }.map(\.id))
    registrations.removeAll { registration in
      guard Self.missing(registration.url) else { return false }
      if registration.scoped { registration.url.stopAccessingSecurityScopedResource() }
      return true
    }
    persistRegistrations()
    if !deleted.isEmpty {
      recent.removeAll { deleted.contains($0) }
      pinned.removeAll { deleted.contains($0) }
      hidden.removeAll { deleted.contains($0) }
      hub.removeAll { deleted.contains($0) }
      defaults.set(recent, forKey: "recent")
      defaults.set(pinned, forKey: "pinned")
      defaults.set(hidden, forKey: "hidden")
      defaults.set(hub, forKey: "hub")
    }
    return [documents] + registrations.map(\.url)
  }
  /// What a walk found, and whether it looked everywhere: an unreadable folder or a walk cut
  /// short may hide noodlets.
  struct Discovery: Sendable {
    var entries: [String: LibraryEntry] = [:]
    var complete = true
  }
  /// Every noodlet in `places` and in the workspaces of the bots in `botFolders`.
  nonisolated static func discover(in places: [URL], botFolders: [URL], thumbnails: URL) -> Discovery {
    final class Flag: @unchecked Sendable { var complete = true }
    let flag = Flag()
    let workspaces = botFolders.flatMap { folder in
      guard FileManager.default.fileExists(atPath: folder.path) else { return [URL]() }
      guard let bots = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
        flag.complete = false
        return []
      }
      return bots.map { $0.appendingPathComponent("workspace", isDirectory: true) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    var found: [String: LibraryEntry] = [:]
    for directory in places + workspaces {
      if AppletBuildIdentity.document(directory) == .current {
        if let package = try? NoodletPackage(url: directory) {
          let entry = LibraryEntry(package: package, thumbnails: thumbnails)
          found[entry.id] = entry
        }
        continue
      }
      guard
        let walker = FileManager.default.enumerator(
          at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey],
          options: [.skipsHiddenFiles], errorHandler: { _, _ in flag.complete = false; return true })
      else { flag.complete = false; continue }
      var count = 0
      for case let url as URL in walker {
        count += 1
        if count > 10000 { flag.complete = false; break }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
          walker.skipDescendants()
          continue
        }
        if AppletBuildIdentity.document(url) == .current {
          walker.skipDescendants()
          if let package = try? NoodletPackage(url: url) {
            let entry = LibraryEntry(package: package, thumbnails: thumbnails)
            found[entry.id] = entry
          }
        } else if walker.level > 4 {
          walker.skipDescendants()
        }
      }
    }
    return Discovery(entries: found, complete: flag.complete)
  }
  private func apply(_ found: [String: LibraryEntry]) {
    let next = found.values.sorted {
      let order = $0.title.localizedStandardCompare($1.title)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
    if entries != next { entries = next }
    for entry in entries where isHub(entry.package.url) { markHub(entry.id) }
    // Read once for each bot: agent.json holds its picture too.
    var people: [URL: HubPerson?] = [:]
    let owners = entries.reduce(into: [String: HubPerson]()) { owners, entry in
      guard let bot = bot(holding: entry.package.url), bot.folder.isHub else { return }
      let folder = bot.folder.url.appendingPathComponent(bot.owner)
      if people[folder] == nil { people[folder] = .some(Self.person(owning: folder)) }
      owners[entry.id] = people[folder] ?? nil
    }
    if hubOwners != owners { hubOwners = owners }
    for entry in entries {
      do { _ = try linkID(for: entry.package) } catch { self.error = error.localizedDescription }
    }
  }
  func linkID(for package: NoodletPackage) throws -> UUID {
    guard let links else { throw NSError(domain: "NoodletRegistry", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Noodlet link registry is unavailable."]) }
    return try links.id(for: package.url)
  }
  func package(for id: UUID) throws -> NoodletPackage {
    guard let url = links?.resolve(id) else { throw NSError(domain: "NoodletRegistry", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "This noodlet is no longer available."]) }
    let package = try NoodletPackage(url: url)
    // A bookmark can follow a moved file before the library's next scan.
    if !entries.contains(where: { $0.package.url == package.url }) { try grant(url) }
    return package
  }
  func remember(_ package: NoodletPackage) {
    recent.removeAll { $0 == package.key }
    recent.insert(package.key, at: 0)
    recent = Array(recent.prefix(30))
    defaults.set(recent, forKey: "recent")
    // Only it can be new here, so the workspaces are not walked again on the main thread.
    guard !entries.contains(where: { $0.id == package.key }) else { return }
    let entry = LibraryEntry(package: package, thumbnails: root.appendingPathComponent("Thumbnails", isDirectory: true))
    apply(Dictionary(entries.map { ($0.id, $0) } + [(entry.id, entry)], uniquingKeysWith: { $1 }))
  }
  /// Pinned noodlets for the menu bar, in pin order.
  var menuPinned: [LibraryEntry] {
    pinned.filter { !hidden.contains($0) }.compactMap { key in entries.first { $0.id == key } }
  }
  /// The most recent noodlets for the menu bar that are not already pinned there.
  var menuRecent: [LibraryEntry] {
    Array(
      recent.filter { !pinned.contains($0) && !hidden.contains($0) && !hub.contains($0) }
        .compactMap { key in entries.first { $0.id == key } }.prefix(8))
  }
  /// Categories holding at least one of the space's noodlets that is not hidden, in the fixed category order.
  func categories(in space: CompanionSpace) -> [String] {
    let used = Set(entries.filter { !hidden.contains($0.id) && hub.contains($0.id) == (space == .hub) }
      .compactMap(\.package.manifest.category))
    return NoodletManifest.knownCategories.filter(used.contains)
  }
  /// Whether Noodle Hub's bots made any of the noodlets, giving the library a Hub space.
  var hasHub: Bool { entries.contains { hub.contains($0.id) } }
  /// People with noodlets under Hub that are not hidden, by name.
  var hubPeople: [HubPerson] {
    let people = Set(hubOwners.filter { !hidden.contains($0.key) }.values)
    return people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  private static func person(owning bot: URL) -> HubPerson? {
    struct Configuration: Decodable { let owner: HubPerson? }
    guard let data = try? Data(contentsOf: bot.appendingPathComponent("agent.json")) else { return nil }
    return (try? JSONDecoder().decode(Configuration.self, from: data))?.owner
  }
  func markHub(_ key: String) {
    guard !hub.contains(key) else { return }
    hub.append(key)
    defaults.set(hub, forKey: "hub")
  }
  /// Hides a noodlet, or shows a hidden one again. Its pin is kept for when it is shown.
  func hide(_ key: String) {
    if hidden.contains(key) { hidden.removeAll { $0 == key } } else { hidden.append(key) }
    defaults.set(hidden, forKey: "hidden")
  }
  /// Moves a noodlet to the Trash, then deletes what it saved, its secrets, permissions and thumbnail.
  /// Nothing is deleted when the move fails.
  func trash(
    _ package: NoodletPackage, secrets: AppletSecrets = .shared,
    moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
  ) async throws {
    try moveToTrash(package.url)
    scan()
    await AppletStorage.remove(package.key, root: root, defaults: defaults)
    AppletPermissions.revoke(packageKey: package.key, defaults: defaults)
    for scope in ["user", "test"] { try? secrets.storage.save([:], account: "\(package.key).\(scope)") }
    try? FileManager.default.removeItem(at: root.appendingPathComponent("Thumbnails/\(package.key).png"))
  }
  func pin(_ key: String) {
    if pinned.contains(key) { pinned.removeAll { $0 == key } } else { pinned.append(key) }
    defaults.set(pinned, forKey: "pinned")
  }
  func grant(_ url: URL) throws {
    let active = url.startAccessingSecurityScopedResource()
    var retained = false
    defer { if active && !retained { url.stopAccessingSecurityScopedResource() } }
    let package = try NoodletPackage(url: url)
    if !registrations.contains(where: { Self.canonical($0.url) == package.url }) {
      let bookmark = try url.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
      registrations.append(Registration(url: url, bookmark: bookmark, scoped: active))
      retained = true
      persistRegistrations()
    }
    scan()
  }
  deinit {
    timer?.invalidate()
    for registration in registrations where registration.scoped {
      registration.url.stopAccessingSecurityScopedResource()
    }
  }
  func choosePackage(open: @escaping (NoodletPackage) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.treatsFilePackagesAsDirectories = false
    panel.allowedContentTypes = [UTType(AppletBuildIdentity.current.contentType) ?? .package]
    panel.prompt = "Open Noodlet"
    panel.begin { [weak self] result in
      Task { @MainActor in
        guard result == .OK, let url = panel.url else { return }
        do {
          try self?.grant(url)
          open(try NoodletPackage(url: url))
        } catch { self?.error = error.localizedDescription }
      }
    }
  }
}
