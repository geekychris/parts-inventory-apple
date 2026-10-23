import Foundation

/// One part as a flat row: what the inventory table, its facets and the CSV, Excel and repository exports
/// show. Built from a backup, so this inventory and a friend's published one read the same way.
public struct InventoryRow: Identifiable, Hashable, Sendable {
    public var id: String
    /// Whose inventory: "" for this one, otherwise the name given to a friend's.
    public var source: String
    public var mpn: String
    public var manufacturer: String
    public var description: String
    /// "Passives/Resistors" as stored; `categoryPath` splits it.
    public var category: String
    public var categoryPath: [String]
    public var package: String
    public var params: PartParams
    /// "10 kΩ ±1% 0.1 W 0603".
    public var value: String
    public var qty: Int
    public var lowStock: Int?
    public var location: String
    public var locationPath: [String]
    public var datasheet: String
    public var suppliers: [SupplierEntry]
    public var tags: [String]
    public var notes: String
    public var updated: Date

    public var title: String { !mpn.isEmpty ? mpn : !description.isEmpty ? description : "Unnamed part" }
    public var isLow: Bool { lowStock.map { qty <= $0 } ?? false }
}

extension Backup {
    /// The parts as rows, with location paths resolved. `defaultLowStock` applies where a part has no limit
    /// of its own (0 or nil: none).
    public func rows(source: String = "", defaultLowStock: Int? = nil) -> [InventoryRow] {
        let byID = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func path(_ id: String?) -> [String] {
            var out: [String] = [], seen = Set<String>(), cur = id
            while let c = cur, let l = byID[c], seen.insert(c).inserted { out.insert(l.name, at: 0); cur = l.parentId }
            return out
        }
        return parts.map { p in
            let loc = path(p.locationId)
            let low = p.lowStock.map { Int($0) } ?? defaultLowStock.flatMap { $0 > 0 ? $0 : nil }
            return InventoryRow(
                id: p.id, source: source, mpn: p.mpn, manufacturer: p.manufacturer, description: p.description,
                category: p.category, categoryPath: InventoryRow.split(p.category), package: p.package, params: p.params,
                value: Values.summary(p.params), qty: Int(p.qty), lowStock: low,
                location: loc.joined(separator: " › "), locationPath: loc, datasheet: p.datasheet, suppliers: p.suppliers,
                tags: p.tags, notes: p.notes, updated: Date(jsTime: p.updated))
        }
    }
}

extension InventoryRow {
    /// "Passives / Resistors" → ["Passives", "Resistors"].
    public static func split(_ category: String) -> [String] {
        category.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
