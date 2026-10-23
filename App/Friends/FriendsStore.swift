import Foundation
import PartsKit

/// A friend's inventory: a name and where it's published — a web address (usually a GitHub repository) or a
/// folder on this device. Read-only: nothing here is ever written back or mixed into this inventory.
struct Friend: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    /// The address as typed ("https://github.com/sam/parts"); empty for a folder.
    var address = ""
    /// A folder: a security-scoped bookmark, and its path for showing (and for reading when there's no bookmark).
    var bookmark: Data?
    var folderPath: String?

    var isFolder: Bool { bookmark != nil || folderPath != nil }
    var whereLabel: String { isFolder ? (folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "A folder") : address }
}

/// The friends, their last good copy (cached on disk so the table works offline) and how each fetch went.
@Observable
final class FriendsStore {
    static let shared = FriendsStore()

    struct Status: Equatable {
        var fetched: Date?
        var error: String?
        var loading = false
        var parts = 0
    }

    private(set) var friends: [Friend] = []
    private(set) var status: [Friend.ID: Status] = [:]
    /// Each friend's parts as rows (source = the friend's name).
    private(set) var rows: [Friend.ID: [InventoryRow]] = [:]
    /// Bumped whenever any friend's rows change, for the table to rebuild.
    private(set) var version = 0

    static let refreshAge: TimeInterval = 3600
    private static let defaultsKey = "friends"
    /// Under tests and `-memoryStore` runs, keep the list in memory and the cache in a temporary folder, away
    /// from the real app's friends.
    private let ephemeral: Bool
    private let cacheDir: URL

    init() {
        let p = ProcessInfo.processInfo
        ephemeral = p.environment["XCTestConfigurationFilePath"] != nil || p.arguments.contains("-memoryStore")
        cacheDir = ephemeral
            ? FileManager.default.temporaryDirectory.appendingPathComponent("Friends-\(p.processIdentifier)", isDirectory: true)
            : URL.applicationSupportDirectory.appendingPathComponent("Friends", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if !ephemeral, let d = UserDefaults.standard.data(forKey: Self.defaultsKey), let l = try? JSONDecoder().decode([Friend].self, from: d) {
            friends = l
        }
        for f in friends { loadCache(f) }
    }

    var hasFriends: Bool { !friends.isEmpty }
    var allRows: [InventoryRow] { friends.flatMap { rows[$0.id] ?? [] } }

    // MARK: Changing the list

    /// Add a friend at a web address; the address is checked first. Throws a readable error.
    @discardableResult
    func add(name: String, address: String) throws -> Friend {
        _ = try RemoteInventory.resolve(address)
        let f = Friend(name: try uniqueName(name), address: address.trimmingCharacters(in: .whitespacesAndNewlines))
        insert(f)
        return f
    }

    /// Add a friend's folder on this device (from a folder picker, so it can be read again later).
    @discardableResult
    func add(name: String, folder: URL) throws -> Friend {
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let bookmark = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try? folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        let f = Friend(name: try uniqueName(name), bookmark: bookmark, folderPath: folder.path)
        insert(f)
        return f
    }

    func update(_ f: Friend) {
        guard let i = friends.firstIndex(where: { $0.id == f.id }) else { return }
        let renamed = friends[i].name != f.name
        friends[i] = f
        save()
        if renamed, let r = rows[f.id] { rows[f.id] = r.map { var x = $0; x.source = f.name; return x }; version += 1 }
    }

    func remove(_ f: Friend) {
        friends.removeAll { $0.id == f.id }
        rows[f.id] = nil; status[f.id] = nil; version += 1
        try? FileManager.default.removeItem(at: cacheFile(f))
        save()
    }

    func uniqueName(_ name: String, except id: Friend.ID? = nil) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw Problem("Give your friend a name.") }
        guard !friends.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(n) == .orderedSame }) else {
            throw Problem("There’s already a friend called \(n).")
        }
        return n
    }

    private func insert(_ f: Friend) {
        friends.append(f)
        friends.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
        status[f.id, default: Status()].loading = true
        Task { await refresh(f) }
    }

    private func save() {
        guard !ephemeral, let d = try? JSONEncoder().encode(friends) else { return }
        UserDefaults.standard.set(d, forKey: Self.defaultsKey)
    }

    // MARK: Fetching

    /// Fetch every friend's inventory that's older than `age` (or failed last time).
    func refreshAll(olderThan age: TimeInterval = 0) async {
        await withTaskGroup { g in
            for f in friends where status[f.id]?.loading != true {
                let s = status[f.id]
                if age > 0, let t = s?.fetched, s?.error == nil, Date.now.timeIntervalSince(t) < age { continue }
                g.addTask { await self.refresh(f) }
            }
        }
    }

    func refresh(_ f: Friend) async {
        status[f.id, default: Status()].loading = true
        do {
            let data = try await fetch(f)
            let backup = try RemoteInventory.decode(data)
            guard friends.contains(where: { $0.id == f.id }) else { return }   // removed meanwhile
            try? data.write(to: cacheFile(f), options: .atomic)
            apply(backup, to: f, fetched: .now)
        } catch {
            status[f.id, default: Status()].error = error.localizedDescription
        }
        status[f.id, default: Status()].loading = false
    }

    private func fetch(_ f: Friend) async throws -> Data {
        if f.isFolder {
            let folder = try resolveFolder(f)
            let ok = folder.startAccessingSecurityScopedResource()
            defer { if ok { folder.stopAccessingSecurityScopedResource() } }
            return try RemoteInventory.readData(folder: folder)
        }
        return try await RemoteInventory.fetchData(RemoteInventory.resolve(f.address))
    }

    private func resolveFolder(_ f: Friend) throws -> URL {
        if let b = f.bookmark {
            var stale = false
            #if os(macOS)
            let url = try? URL(resolvingBookmarkData: b, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            let url = try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            if let url { return url }
        }
        if let p = f.folderPath { return URL(fileURLWithPath: p, isDirectory: true) }
        throw Problem("The folder can’t be found any more. Remove this friend and choose the folder again.")
    }

    private func apply(_ b: Backup, to f: Friend, fetched: Date?) {
        rows[f.id] = b.rows(source: f.name)
        status[f.id, default: Status()].fetched = fetched
        status[f.id, default: Status()].error = nil
        status[f.id, default: Status()].parts = b.parts.count
        version += 1
    }

    private func cacheFile(_ f: Friend) -> URL { cacheDir.appendingPathComponent("\(f.id).json") }

    private func loadCache(_ f: Friend) {
        let url = cacheFile(f)
        guard let d = try? Data(contentsOf: url), let b = try? RemoteInventory.decode(d) else { return }
        let t = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        apply(b, to: f, fetched: t)
    }

    #if DEBUG
    /// `-friend "Sam=https://…"` or `-friend "Sam=/path/to/folder"`: a friend for this run only.
    func addForDebug(_ spec: String) {
        guard let eq = spec.firstIndex(of: "=") else { return }
        let name = String(spec[..<eq]), target = String(spec[spec.index(after: eq)...])
        let f = target.hasPrefix("/") ? Friend(name: name, folderPath: target) : Friend(name: name, address: target)
        friends.append(f)
        status[f.id, default: Status()].loading = true
        Task { await refresh(f) }
    }
    #endif
}

/// A plain error message.
struct Problem: LocalizedError {
    var message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
