import Foundation

/// A way of narrowing the inventory table. Category and location are trees: choosing a node includes
/// everything below it.
public enum FacetKind: String, CaseIterable, Codable, Sendable {
    case source, category, stock, kind, manufacturer, package, location, tags

    public var title: String {
        switch self {
        case .source: "Source"
        case .category: "Category"
        case .stock: "Stock"
        case .kind: "Kind"
        case .manufacturer: "Manufacturer"
        case .package: "Package"
        case .location: "Location"
        case .tags: "Tags"
        }
    }
    public var isTree: Bool { self == .category || self == .location }

    /// Tree keys are paths joined by this.
    public static let separator = " › "
    /// The key for "no value" (no category, no manufacturer…).
    public static let none = ""

    /// How a key reads: "Mine" for this inventory's source, "None" for an empty value, stock in words.
    public func label(_ key: String) -> String {
        switch self {
        case .source: key.isEmpty ? "Mine" : key
        case .stock: StockLevel(rawValue: key)?.label ?? key
        case .kind: key.isEmpty ? "Other" : FacetKind.kindNames[key] ?? key
        default: key.isEmpty ? "None" : key
        }
    }

    static let kindNames = ["R": "Resistors", "C": "Capacitors", "L": "Inductors", "D": "Diodes", "LED": "LEDs", "Q": "Transistors",
                            "U": "ICs", "J": "Connectors", "Y": "Crystals", "F": "Fuses", "SW": "Switches"]

    /// The keys a row has for this facet. A tree row has every ancestor of its node, so counts and
    /// matches include descendants.
    public func keys(_ r: InventoryRow) -> [String] {
        func prefixes(_ path: [String]) -> [String] {
            path.isEmpty ? [FacetKind.none] : (1...path.count).map { path.prefix($0).joined(separator: FacetKind.separator) }
        }
        switch self {
        case .source: return [r.source]
        case .category: return prefixes(r.categoryPath)
        case .location: return prefixes(r.locationPath)
        case .stock: return [StockLevel(r).rawValue]
        case .kind: return [r.params.kind ?? FacetKind.none]
        case .manufacturer: return [r.manufacturer.trimmed]
        case .package:
            let p = r.package.trimmed.isEmpty ? (r.params.pkg ?? "") : r.package.trimmed
            return [Values.normPackage(p).isEmpty ? p : Values.normPackage(p)]
        case .tags: return r.tags.map(\.trimmed).filter { !$0.isEmpty }
        }
    }
}

/// In stock, low (at or under its warning level) or out.
public enum StockLevel: String, CaseIterable, Sendable {
    case inStock = "in", low, out
    public init(_ r: InventoryRow) { self = r.qty <= 0 ? .out : r.isLow ? .low : .inStock }
    public var label: String { switch self { case .inStock: "In stock"; case .low: "Low"; case .out: "Out of stock" } }
}

/// What's chosen in each facet. Values within a facet OR together; facets AND.
public struct FacetFilter: Equatable, Hashable, Codable, Sendable {
    public var selected: [FacetKind: Set<String>] = [:]
    public init() {}

    public var isEmpty: Bool { selected.values.allSatisfy(\.isEmpty) }
    public func contains(_ f: FacetKind, _ key: String) -> Bool { selected[f]?.contains(key) ?? false }
    public mutating func toggle(_ f: FacetKind, _ key: String) {
        var s = selected[f] ?? []
        if s.remove(key) == nil { s.insert(key) }
        selected[f] = s.isEmpty ? nil : s
    }
    public mutating func remove(_ f: FacetKind, _ key: String) {
        selected[f]?.remove(key)
        if selected[f]?.isEmpty == true { selected[f] = nil }
    }
    public mutating func clear() { selected = [:] }

    /// The chosen values in facet order, for chips.
    public var chips: [Chip] {
        FacetKind.allCases.flatMap { f in (selected[f] ?? []).sorted().map { Chip(facet: f, key: $0) } }
    }
    public struct Chip: Hashable, Identifiable, Sendable {
        public var facet: FacetKind, key: String
        public var id: String { facet.rawValue + "\u{1F}" + key }
    }
}

/// A facet value with how many rows it would show, given the other facets. Tree values have children.
public struct FacetNode: Identifiable, Hashable, Sendable {
    public var key: String
    public var label: String
    public var count: Int
    public var children: [FacetNode]
    public var id: String { key }
    /// Every node in this subtree, for "Show all" counts and searching.
    public var size: Int { 1 + children.reduce(0) { $0 + $1.size } }
}

/// The rows with each one's facet keys and search text worked out once, so filtering and counting a few
/// thousand rows on every keystroke stays quick.
public struct FacetIndex: Sendable {
    public let rows: [InventoryRow]
    let keys: [[Set<String>]]   // [row][facet]
    let text: [String]

    public init(_ rows: [InventoryRow]) {
        self.rows = rows
        keys = rows.map { r in FacetKind.allCases.map { Set($0.keys(r)) } }
        text = rows.map(\.searchText)
    }

    public struct Result: Sendable {
        /// Indexes into `rows` of the rows that match everything.
        public var matches: [Int]
        /// Each facet's values, counted over the rows that match the search and every other facet.
        public var facets: [FacetKind: [FacetNode]]
    }

    /// Filter by the search and facets, and count each facet's values (standard faceted search: a facet's counts
    /// ignore its own selection, so choosing one value doesn't hide the others).
    public func result(_ query: PartQuery, _ filter: FacetFilter) -> Result {
        let all = FacetKind.allCases
        let wanted = all.map { filter.selected[$0].flatMap { $0.isEmpty ? nil : $0 } }
        var counts = Array(repeating: [String: Int](), count: all.count)
        var matches: [Int] = []
        for i in rows.indices {
            if !query.isEmpty && !query.matches(rows[i], text: text[i]) { continue }
            // Which facets does this row fail? None: it's shown and counts everywhere; one: it counts only there.
            var failed = -1, fails = 0
            for f in all.indices where wanted[f] != nil && keys[i][f].isDisjoint(with: wanted[f]!) {
                fails += 1; failed = f
                if fails > 1 { break }
            }
            if fails > 1 { continue }
            if fails == 0 { matches.append(i) }
            for f in all.indices where fails == 0 || f == failed {
                for k in keys[i][f] { counts[f][k, default: 0] += 1 }
            }
        }
        var facets: [FacetKind: [FacetNode]] = [:]
        for (fi, f) in all.enumerated() {
            // Chosen values stay listed (with 0) so they can be unchosen.
            for k in wanted[fi] ?? [] where counts[fi][k] == nil { counts[fi][k] = 0 }
            facets[f] = f.isTree ? Self.tree(f, counts[fi]) : Self.flat(f, counts[fi])
        }
        return Result(matches: matches, facets: facets)
    }

    static func flat(_ f: FacetKind, _ counts: [String: Int]) -> [FacetNode] {
        let nodes = counts.map { FacetNode(key: $0.key, label: f.label($0.key), count: $0.value, children: []) }
        switch f {
        case .stock: return StockLevel.allCases.compactMap { s in nodes.first { $0.key == s.rawValue } }
        case .source: return nodes.sorted { ($0.key.isEmpty ? 0 : 1, $0.label.lowercased()) < ($1.key.isEmpty ? 0 : 1, $1.label.lowercased()) }
        default:
            // Most first; "None" last.
            return nodes.sorted { a, b in
                if a.key.isEmpty != b.key.isEmpty { return b.key.isEmpty }
                return a.count != b.count ? a.count > b.count : a.label.localizedStandardCompare(b.label) == .orderedAscending
            }
        }
    }

    static func tree(_ f: FacetKind, _ counts: [String: Int]) -> [FacetNode] {
        let sep = FacetKind.separator
        func build(_ parent: String?) -> [FacetNode] {
            counts.keys.filter { k in
                guard let parent else { return !k.contains(sep) }
                return k.hasPrefix(parent + sep) && !k.dropFirst(parent.count + sep.count).contains(sep)
            }
            .map { k in
                FacetNode(key: k, label: k.isEmpty ? f.label(k) : String(k.components(separatedBy: sep).last!), count: counts[k]!,
                          children: k.isEmpty ? [] : build(k))
            }
            .sorted { a, b in
                if a.key.isEmpty != b.key.isEmpty { return b.key.isEmpty }
                return a.label.localizedStandardCompare(b.label) == .orderedAscending
            }
        }
        return build(nil)
    }
}

extension InventoryRow {
    /// A backup part as a row, given its location path and low-stock level (the app maps its own parts this way,
    /// without making a whole backup).
    public init(_ p: Backup.Part, source: String = "", locationPath: [String], lowStock: Int?) {
        self.init(id: p.id, source: source, mpn: p.mpn, manufacturer: p.manufacturer, description: p.description,
                  category: p.category, categoryPath: InventoryRow.split(p.category), package: p.package, params: p.params,
                  value: Values.summary(p.params), qty: Int(p.qty), lowStock: lowStock,
                  location: locationPath.joined(separator: " › "), locationPath: locationPath, datasheet: p.datasheet,
                  suppliers: p.suppliers, tags: p.tags, notes: p.notes, updated: Date(jsTime: p.updated))
    }

    /// A short message asking to borrow some: "Could I borrow 2 × LM358DR (IC OPAMP GP 2 CIRCUIT 8SOIC)? Your
    /// inventory has it in Cabinet A › Drawer 2."
    public func borrowRequest(_ qty: Int) -> String {
        let what = [description.trimmed.isEmpty ? value : description.trimmed, manufacturer.trimmed]
            .filter { !$0.isEmpty && $0 != title }.first
        var s = "Could I borrow \(qty) × \(title)\(what.map { " (\($0))" } ?? "")?"
        if !location.isEmpty { s += " Your inventory has it in \(location)." }
        return s
    }
}
