import Foundation

/// A part that turns up on hobby boards: chips by the marking printed on them, boards and modules by
/// their silkscreen and how they look. Shared with the web tool (Resources/catalog.json is exported
/// from its parts-identify-core.js by tools/export-catalog.sh).
public struct CatalogEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var mpn: String
    /// A friendly name for boards ("Arduino Uno").
    public var name: String?
    public var mfr: String
    /// ic, module, board or discrete.
    public var kind: String
    public var cat: String
    public var pkg: String
    public var desc: String
    public var marks: [String]?
    public var ds: String?
    public var mfrWords: [String]?
    /// A description for recognising it by look.
    public var look: String?

    public var displayName: String { name ?? mpn }
}

/// A kind of part with no part number to read: "a potentiometer", "a relay module".
public struct GenericKind: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var cat: String
    public var look: String
}

public struct Catalog: Sendable {
    public var entries: [CatalogEntry]
    public var generic: [GenericKind]
    /// Generic kinds that mean "a board or module": then it's worth asking which board.
    public var boardish: [String]

    public static let shared: Catalog = {
        struct File: Decodable { var catalog: [CatalogEntry]; var generic: [GenericKind]; var boardish: [String] }
        let url = Bundle.module.url(forResource: "catalog", withExtension: "json")!
        let f = try! JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return Catalog(entries: f.catalog, generic: f.generic, boardish: f.boardish)
    }()

    public func entry(_ id: String) -> CatalogEntry? { entries.first { $0.id == id } }
    public func genericKind(_ id: String) -> GenericKind? { generic.first { $0.id == id } }

    /// Find entries by text, for a "search the list" box.
    public func search(_ q: String, limit: Int = 12) -> [CatalogEntry] {
        let words = q.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let sq = Identify.squash(q)
        return entries.compactMap { e -> (CatalogEntry, Int)? in
            let hay = ([e.mpn, e.name ?? "", e.mfr, e.desc, e.cat] + (e.marks ?? [])).joined(separator: " ").lowercased()
            let hits = words.filter { hay.contains($0) }.count
            guard hits == words.count else { return nil }
            return (e, hits + ((e.marks ?? []).contains { Identify.squash($0) == sq } ? 2 : 0))
        }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
