import Foundation

/// The inventory as a folder for a git repository: `inventory.json` (a backup, the machine-readable source
/// of truth), `README.md`, `parts.csv`, a Markdown page per top-level category under `categories/`, and
/// optionally `photos/`. GitHub shows it as a browsable catalogue; the app reads `inventory.json` back.
/// See docs/repository-format.md.
///
/// The same inventory gives byte-identical files, apart from the exported date in README.md and inventory.json.
public enum Repository {
    public struct Options: Sendable, Equatable {
        /// The title of README.md.
        public var name: String
        /// Projects and stock history too (a full backup); otherwise only parts and locations.
        public var full: Bool
        /// Photos in `photos/`, shown on the category pages.
        public var photos: Bool
        public init(name: String = "Parts inventory", full: Bool = false, photos: Bool = false) {
            self.name = name; self.full = full; self.photos = photos
        }
    }

    /// The paths an export owns: these are replaced or removed; nothing else in the folder is touched.
    public static let ownedFiles = ["inventory.json", "README.md", "parts.csv"]
    public static let ownedFolders = ["categories", "photos"]

    public static func owns(_ path: String) -> Bool {
        ownedFiles.contains(path) || ownedFolders.contains { path.hasPrefix($0 + "/") }
    }

    /// The files of an export, by path relative to the folder. `backup` is the whole inventory; photos are
    /// used only when `options.photos` is on.
    public static func files(_ backup: Backup, options: Options = Options(), exported: Date = .now, defaultLowStock: Int? = nil) throws -> [String: Data] {
        var b = backup
        let locPath = locationPaths(b.locations)
        b.parts.sort { x, y in
            x.category != y.category ? Export.less(x.category, y.category) : x.mpn != y.mpn ? Export.less(x.mpn, y.mpn) : x.id < y.id
        }
        b.locations.sort { x, y in
            let a = locPath[x.id] ?? "", c = locPath[y.id] ?? ""
            return a != c ? Export.less(a, c) : x.id < y.id
        }
        b.exportedAt = ISO8601DateFormatter().string(from: exported)
        if !options.full { b.projects = []; b.history = [] }
        b.projects.sort { $0.id < $1.id }
        b.history.sort { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }

        // Photos: each part's photos as files; a part's first one (in its own order) shows on its page.
        var photoFiles: [String: Data] = [:], photoOf: [String: String] = [:]
        if options.photos {
            let partIDs = Set(b.parts.map(\.id))
            var nameOf: [String: String] = [:]
            for ph in (b.photos ?? []).sorted(by: { $0.id < $1.id }) where ph.partId.map(partIDs.contains) ?? false {
                let raw = ph.data.replacingOccurrences(of: "^data:[^,]*,", with: "", options: .regularExpression)
                guard let d = Data(base64Encoded: raw) else { continue }
                let name = "photos/\(fileSafe(ph.id)).\(fileExtension(ph.type))"
                photoFiles[name] = d; nameOf[ph.id] = name
                if let p = ph.partId, photoOf[p] == nil { photoOf[p] = name }
            }
            for p in b.parts { if let first = p.photoIds.lazy.compactMap({ nameOf[$0] }).first { photoOf[p.id] = first } }
        } else {
            for i in b.parts.indices { b.parts[i].photoIds = [] }
        }
        b.photos = nil

        var files: [String: Data] = [:]
        files["inventory.json"] = try b.encoded() + Data("\n".utf8)
        let rows = b.rows(defaultLowStock: defaultLowStock)
        files["parts.csv"] = CSV.data(InventoryRow.table(rows), options: .plain)

        let pages = categoryPages(rows)
        for page in pages {
            files["categories/\(page.slug).md"] = Data(Markdown.categoryPage(page, inventory: options.name, photos: options.photos ? photoOf : nil).utf8)
        }
        files["README.md"] = Data(Markdown.readme(name: options.name, exported: exported, rows: rows, pages: pages, full: options.full, photos: options.photos).utf8)
        files.merge(photoFiles) { a, _ in a }
        return files
    }

    /// Write an export into a folder: changed files are written, unchanged ones left alone, and files the
    /// exporter owns that this export no longer has are removed. Returns the paths written and removed.
    @discardableResult
    public static func write(_ files: [String: Data], to folder: URL) throws -> (written: [String], removed: [String]) {
        let fm = FileManager.default
        var written: [String] = [], removed: [String] = []
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            precondition(owns(path), "not an exporter's file: \(path)")
            let url = folder.appending(path: path)
            if let old = try? Data(contentsOf: url), old == data { continue }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            written.append(path)
        }
        for dir in ownedFolders {
            let root = folder.appending(path: dir)
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            var dirs: [URL] = []
            for case let url as URL in e {
                let rel = ([dir] + url.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count)).joined(separator: "/")
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { dirs.append(url); continue }
                if files[rel] == nil { try fm.removeItem(at: url); removed.append(rel) }
            }
            // Folders left empty, deepest first.
            for d in ([root] + dirs).sorted(by: { $0.path.count > $1.path.count }) where (try? fm.contentsOfDirectory(atPath: d.path))?.isEmpty == true {
                try fm.removeItem(at: d)
            }
        }
        return (written, removed.sorted())
    }

    // ------------------------------------------------------------ categories

    /// A top-level category's page: its parts grouped by the rest of their category path.
    public struct CategoryPage: Sendable {
        public var name: String          // "" for parts without a category
        public var slug: String
        public var groups: [(path: [String], rows: [InventoryRow])]
        public var title: String { name.isEmpty ? "Uncategorised" : name }
        public var count: Int { groups.reduce(0) { $0 + $1.rows.count } }
        public var units: Int { groups.reduce(0) { $0 + $1.rows.reduce(0) { $0 + $1.qty } } }
    }

    public static func categoryPages(_ rows: [InventoryRow]) -> [CategoryPage] {
        let byTop = Dictionary(grouping: rows) { $0.categoryPath.first ?? "" }
        // Named categories in order, uncategorised last; slugs made unique in that order.
        let names = byTop.keys.filter { !$0.isEmpty }.sorted(by: Export.less) + (byTop[""] == nil ? [] : [""])
        var used = Set<String>()
        return names.map { name in
            let base = slug(name.isEmpty ? "Uncategorised" : name)
            var s = base, n = 2
            while used.contains(s) { s = "\(base)-\(n)"; n += 1 }
            used.insert(s)
            let bySub = Dictionary(grouping: byTop[name] ?? []) { Array($0.categoryPath.dropFirst()) }
            let groups = bySub.keys.sorted { a, b in Export.less(a.joined(separator: "\u{1}"), b.joined(separator: "\u{1}")) }.map { k in
                (path: k, rows: bySub[k]!.sorted { x, y in x.mpn != y.mpn ? Export.less(x.mpn, y.mpn) : x.id < y.id })
            }
            return CategoryPage(name: name, slug: s, groups: groups)
        }
    }

    /// "Passives & Co" → "passives-co"; letters are folded to ASCII where they can be.
    public static func slug(_ s: String) -> String {
        let folded = s.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? s
        var out = "", dash = false
        for ch in folded.lowercased().unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) { if dash && !out.isEmpty { out += "-" }; out.unicodeScalars.append(ch); dash = false }
            else { dash = true }
        }
        return out.isEmpty ? "category" : out
    }

    static func locationPaths(_ locations: [Backup.Location]) -> [String: String] {
        let byID = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: String] = [:]
        for l in locations {
            var names: [String] = [], seen = Set<String>(), cur: String? = l.id
            while let c = cur, let x = byID[c], seen.insert(c).inserted { names.insert(x.name, at: 0); cur = x.parentId }
            out[l.id] = names.joined(separator: "\u{1}")
        }
        return out
    }

    static func fileSafe(_ s: String) -> String {
        let t = String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" ? Character($0) : "_" })
        return t.isEmpty ? "photo" : t
    }

    static func fileExtension(_ type: String?) -> String {
        switch (type ?? "").lowercased() {
        case "image/png": "png"
        case "image/heic", "image/heif": "heic"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "jpg"
        }
    }
}
