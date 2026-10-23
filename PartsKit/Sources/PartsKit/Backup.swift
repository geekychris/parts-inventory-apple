import Foundation

/// Any JSON value, for the parts of a backup the app keeps but doesn't interpret.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; if case .number(let n) = self { return Values.plain(n) }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
}

/// A supplier's part number for a part, with its price breaks.
public struct SupplierEntry: Codable, Equatable, Hashable, Sendable {
    public struct Break: Codable, Equatable, Hashable, Sendable { public var qty: Double; public var unit: Double }
    public var supplier: String
    public var pn: String
    public var breaks: [Break] = []
    public var currency: String?
    public var stock: Double?
    public var moq: Double?
    public var mult: Double?
    public var url: String = ""
    public var updated: Double = 0

    public init(supplier: String, pn: String) { self.supplier = supplier; self.pn = pn }

    enum CodingKeys: String, CodingKey { case supplier, pn, breaks, currency, stock, moq, mult, url, updated }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        supplier = try c.decode(String.self, forKey: .supplier)
        pn = try c.decode(String.self, forKey: .pn)
        breaks = (try? c.decodeIfPresent([Break].self, forKey: .breaks)) ?? []
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        stock = try? c.decodeIfPresent(Double.self, forKey: .stock)
        moq = try? c.decodeIfPresent(Double.self, forKey: .moq)
        mult = try? c.decodeIfPresent(Double.self, forKey: .mult)
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        updated = (try? c.decodeIfPresent(Double.self, forKey: .updated)) ?? 0
    }
}

/// A price paid: { at, unit, currency, qty, supplier }.
public struct PricePaid: Codable, Equatable, Hashable, Sendable {
    public var at: Double?
    public var unit: Double
    public var currency: String?
    public var qty: Double?
    public var supplier: String?
}

/// The web tool's backup file (schema "gw-parts-inventory", version 1). Times are milliseconds since
/// 1970, as in JavaScript.
public struct Backup: Codable, Sendable {
    public static let schemaName = "gw-parts-inventory"
    public static let version = 1

    public struct Part: Codable, Sendable, Identifiable {
        public var id: String
        public var mpn = "", manufacturer = "", description = "", category = "", package = ""
        public var params = PartParams()
        public var qty: Double = 0
        public var locationId: String?
        public var suppliers: [SupplierEntry] = []
        public var prices: [PricePaid] = []
        public var datasheet = "", image = "", notes = ""
        public var photoIds: [String] = []
        public var lowStock: Double?
        public var tags: [String] = []
        public var created: Double = 0, updated: Double = 0

        public init(id: String) { self.id = id }
        enum CodingKeys: String, CodingKey { case id, mpn, manufacturer, description, category, package, params, qty, locationId, suppliers, prices, datasheet, image, notes, photoIds, lowStock, tags, created, updated }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            func s(_ k: CodingKeys) -> String { ((try? c.decodeIfPresent(JSONValue.self, forKey: k)) ?? nil)?.string ?? "" }
            mpn = s(.mpn); manufacturer = s(.manufacturer); description = s(.description); category = s(.category); package = s(.package)
            datasheet = s(.datasheet); image = s(.image); notes = s(.notes)
            params = (try? c.decodeIfPresent(PartParams.self, forKey: .params)) ?? PartParams()
            qty = Swift.max(0, (try? c.decodeIfPresent(Double.self, forKey: .qty)) ?? 0)
            locationId = try? c.decodeIfPresent(String.self, forKey: .locationId)
            suppliers = ((try? c.decodeIfPresent([JSONValue].self, forKey: .suppliers)) ?? []).compactMap { v in
                (try? JSONEncoder().encode(v)).flatMap { try? JSONDecoder().decode(SupplierEntry.self, from: $0) }
            }.filter { !$0.supplier.isEmpty && !$0.pn.isEmpty }
            prices = ((try? c.decodeIfPresent([JSONValue].self, forKey: .prices)) ?? []).compactMap { v in
                (try? JSONEncoder().encode(v)).flatMap { try? JSONDecoder().decode(PricePaid.self, from: $0) }
            }
            photoIds = (try? c.decodeIfPresent([String].self, forKey: .photoIds)) ?? []
            lowStock = try? c.decodeIfPresent(Double.self, forKey: .lowStock)
            tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
            created = (try? c.decodeIfPresent(Double.self, forKey: .created)) ?? 0
            updated = (try? c.decodeIfPresent(Double.self, forKey: .updated)) ?? 0
        }
    }

    public struct Location: Codable, Sendable, Identifiable {
        public var id: String
        public var parentId: String?
        public var name: String
        public var notes: String = ""
        public var order: Double = 0
        /// A `LocationKind` raw value ("cabinet", "shelf", …); empty when not set.
        public var kind: String = ""
        public var created: Double = 0, updated: Double = 0
        public init(id: String, parentId: String? = nil, name: String) { self.id = id; self.parentId = parentId; self.name = name }
        enum CodingKeys: String, CodingKey { case id, parentId, name, notes, order, kind, created, updated }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            parentId = try? c.decodeIfPresent(String.self, forKey: .parentId)
            let n = ((try? c.decodeIfPresent(JSONValue.self, forKey: .name)) ?? nil)?.string ?? ""
            name = n.trimmed.isEmpty ? "(unnamed)" : n
            notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
            order = (try? c.decodeIfPresent(Double.self, forKey: .order)) ?? 0
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
            created = (try? c.decodeIfPresent(Double.self, forKey: .created)) ?? 0
            updated = (try? c.decodeIfPresent(Double.self, forKey: .updated)) ?? 0
        }
        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encodeIfPresent(parentId, forKey: .parentId); try c.encode(name, forKey: .name)
            try c.encode(notes, forKey: .notes); try c.encode(order, forKey: .order)
            if !kind.isEmpty { try c.encode(kind, forKey: .kind) }
            try c.encode(created, forKey: .created); try c.encode(updated, forKey: .updated)
        }
    }

    /// A project (a BOM). The app shows and keeps projects; the web tool plans builds and orders.
    public struct Project: Codable, Sendable, Identifiable {
        public struct Line: Codable, Sendable, Hashable {
            public var id: String?
            public var refs: [String] = []
            public var qty: Double = 1
            public var value = "", footprint = "", mpn = "", manufacturer = "", description = ""
            public var spn: [String: String] = [:]
            public var dnp = false
            public var partId: String?
            public var params = PartParams()
            enum CodingKeys: String, CodingKey { case id, refs, qty, value, footprint, mpn, manufacturer, description, spn, dnp, partId, params }
            public init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                func s(_ k: CodingKeys) -> String { ((try? c.decodeIfPresent(JSONValue.self, forKey: k)) ?? nil)?.string ?? "" }
                id = try? c.decodeIfPresent(String.self, forKey: .id)
                refs = (try? c.decodeIfPresent([String].self, forKey: .refs)) ?? s(.refs).split(whereSeparator: { " ,;".contains($0) }).map(String.init)
                qty = (try? c.decodeIfPresent(Double.self, forKey: .qty)) ?? 1
                value = s(.value); footprint = s(.footprint); mpn = s(.mpn); manufacturer = s(.manufacturer); description = s(.description)
                spn = (try? c.decodeIfPresent([String: String].self, forKey: .spn)) ?? [:]
                dnp = (try? c.decodeIfPresent(Bool.self, forKey: .dnp)) ?? false
                partId = try? c.decodeIfPresent(String.self, forKey: .partId)
                params = (try? c.decodeIfPresent(PartParams.self, forKey: .params)) ?? PartParams()
            }
        }
        public var id: String
        public var name: String
        public var notes = ""
        public var boards: Double = 1
        public var attritionPct: Double?
        public var minExtra: Double?
        public var lines: [Line] = []
        public var reserved: [String: Double] = [:]
        public var builds: [JSONValue] = []
        public var created: Double = 0, updated: Double = 0
        enum CodingKeys: String, CodingKey { case id, name, notes, boards, attritionPct, minExtra, lines, reserved, builds, created, updated }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            let n = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            name = n.trimmed.isEmpty ? "(unnamed project)" : n
            notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
            boards = (try? c.decodeIfPresent(Double.self, forKey: .boards)) ?? 1
            attritionPct = try? c.decodeIfPresent(Double.self, forKey: .attritionPct)
            minExtra = try? c.decodeIfPresent(Double.self, forKey: .minExtra)
            lines = (try? c.decodeIfPresent([Line].self, forKey: .lines)) ?? []
            reserved = (try? c.decodeIfPresent([String: Double].self, forKey: .reserved)) ?? [:]
            builds = (try? c.decodeIfPresent([JSONValue].self, forKey: .builds)) ?? []
            created = (try? c.decodeIfPresent(Double.self, forKey: .created)) ?? 0
            updated = (try? c.decodeIfPresent(Double.self, forKey: .updated)) ?? 0
        }
    }

    /// A stock change: { at, partId, delta, qtyAfter, reason, supplier?, lot?, … }.
    public struct Change: Codable, Sendable, Identifiable {
        public var id: String
        public var at: Double = 0
        public var partId: String?
        public var delta: Double = 0
        public var qtyAfter: Double?
        public var reason = ""
        public var supplier: String?
        public var lot: String?
        public var created: Double = 0, updated: Double = 0
        public init(id: String, at: Double, partId: String?, delta: Double, qtyAfter: Double?, reason: String) {
            self.id = id; self.at = at; self.partId = partId; self.delta = delta; self.qtyAfter = qtyAfter; self.reason = reason; created = at; updated = at
        }
        enum CodingKeys: String, CodingKey { case id, at, partId, delta, qtyAfter, reason, supplier, lot, created, updated }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            at = (try? c.decodeIfPresent(Double.self, forKey: .at)) ?? 0
            partId = try? c.decodeIfPresent(String.self, forKey: .partId)
            delta = (try? c.decodeIfPresent(Double.self, forKey: .delta)) ?? 0
            qtyAfter = try? c.decodeIfPresent(Double.self, forKey: .qtyAfter)
            reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
            supplier = try? c.decodeIfPresent(String.self, forKey: .supplier)
            lot = try? c.decodeIfPresent(String.self, forKey: .lot)
            created = (try? c.decodeIfPresent(Double.self, forKey: .created)) ?? 0
            updated = (try? c.decodeIfPresent(Double.self, forKey: .updated)) ?? 0
        }
    }

    /// A photo: base64 image data.
    public struct Photo: Codable, Sendable, Identifiable {
        public var id: String
        public var partId: String?
        public var type: String?
        public var name: String?
        public var data: String
        public var created: Double?
        public var updated: Double?
        public init(id: String, partId: String?, type: String?, name: String?, data: String, created: Double?, updated: Double?) {
            self.id = id; self.partId = partId; self.type = type; self.name = name; self.data = data; self.created = created; self.updated = updated
        }
    }

    public var schema = Backup.schemaName
    public var version = Backup.version
    public var exportedAt: String?
    public var app: String?
    public var settings: [String: JSONValue] = [:]
    public var parts: [Part] = []
    public var locations: [Location] = []
    public var projects: [Project] = []
    public var history: [Change] = []
    public var photos: [Photo]?

    public init() {}

    public enum ReadError: LocalizedError {
        case notJSON(String), wrongSchema(String), newerVersion(Int)
        public var errorDescription: String? {
            switch self {
            case .notJSON(let m): "Not a parts-inventory backup: \(m)"
            case .wrongSchema(let s): "Not a parts-inventory backup (schema is \(s), expected \"\(Backup.schemaName)\")."
            case .newerVersion(let v): "This backup is from a newer version (\(v)) of the tool; this app understands version \(Backup.version)."
            }
        }
    }

    /// Read a backup file, checking its schema and version. Items without an id, or with a
    /// duplicate id, are dropped; dangling references are cleared.
    public static func read(_ data: Data) throws -> (backup: Backup, warnings: [String]) {
        struct Head: Decodable { var schema: String?; var version: Int? }
        let head: Head
        do { head = try JSONDecoder().decode(Head.self, from: data) } catch { throw ReadError.notJSON(error.localizedDescription) }
        guard head.schema == schemaName else { throw ReadError.wrongSchema(head.schema.map { "\"\($0)\"" } ?? "missing") }
        if let v = head.version, v > version { throw ReadError.newerVersion(v) }
        struct Loose: Decodable {
            var exportedAt: String?; var app: String?; var settings: [String: JSONValue]?
            var parts: [JSONValue]?; var locations: [JSONValue]?; var projects: [JSONValue]?; var history: [JSONValue]?; var photos: [JSONValue]?
        }
        let loose: Loose
        do { loose = try JSONDecoder().decode(Loose.self, from: data) } catch { throw ReadError.notJSON(error.localizedDescription) }
        var warnings: [String] = []
        var ids = Set<String>()
        func items<T: Decodable & Identifiable>(_ list: [JSONValue]?, _ what: String) -> [T] where T.ID == String {
            var out: [T] = [], bad = 0
            for v in list ?? [] {
                guard let d = try? JSONEncoder().encode(v), let x = try? JSONDecoder().decode(T.self, from: d), !x.id.isEmpty, !ids.contains(x.id) else { bad += 1; continue }
                ids.insert(x.id); out.append(x)
            }
            if bad > 0 { warnings.append("\(bad) \(what) without a usable id were skipped.") }
            return out
        }
        var b = Backup()
        b.exportedAt = loose.exportedAt; b.app = loose.app; b.settings = loose.settings ?? [:]
        b.parts = items(loose.parts, "parts")
        b.locations = items(loose.locations, "locations")
        b.projects = items(loose.projects, "projects")
        b.history = items(loose.history, "history entries")
        b.photos = (loose.photos ?? []).compactMap { v in (try? JSONEncoder().encode(v)).flatMap { try? JSONDecoder().decode(Photo.self, from: $0) } }
        warnings += b.repair()
        return (b, warnings)
    }

    /// Clear dangling references and parent loops. Returns warnings.
    public mutating func repair() -> [String] {
        var w: [String] = []
        let pIds = Set(parts.map(\.id)), lIds = Set(locations.map(\.id))
        var n = 0
        for i in parts.indices where parts[i].locationId != nil && !lIds.contains(parts[i].locationId!) { parts[i].locationId = nil; n += 1 }
        for i in locations.indices where locations[i].parentId != nil && !lIds.contains(locations[i].parentId!) { locations[i].parentId = nil; n += 1 }
        for i in projects.indices {
            for j in projects[i].lines.indices where projects[i].lines[j].partId != nil && !pIds.contains(projects[i].lines[j].partId!) { projects[i].lines[j].partId = nil; n += 1 }
            for k in projects[i].reserved.keys where !pIds.contains(k) { projects[i].reserved[k] = nil; n += 1 }
        }
        if n > 0 { w.append("\(n) reference\(n > 1 ? "s" : "") to missing parts or locations were cleared.") }
        let byId = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var k = 0
        for i in locations.indices {
            var seen: Set<String> = [locations[i].id]
            var p = locations[i].parentId.flatMap { byId[$0] }
            while let q = p {
                if seen.contains(q.id) { locations[i].parentId = nil; k += 1; break }
                seen.insert(q.id); p = q.parentId.flatMap { byId[$0] }
            }
        }
        if k > 0 { w.append("\(k) location(s) in a parent loop moved to the top level.") }
        return w
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

/// Ids in the web tool's style: a prefix, the time in base 36, a counter and random letters.
public enum IDs {
    nonisolated(unsafe) private static var n = 0
    private static let lock = NSLock()
    public static func make(_ prefix: String) -> String {
        lock.lock(); defer { lock.unlock() }
        n += 1
        let t = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let c = String(n % 1296, radix: 36)
        let r = String((0..<5).map { _ in "0123456789abcdefghijklmnopqrstuvwxyz".randomElement()! })
        return prefix + t + String(repeating: "0", count: max(0, 2 - c.count)) + c + r
    }
}

extension Date {
    /// Milliseconds since 1970, as JavaScript stores times.
    public var jsTime: Double { (timeIntervalSince1970 * 1000).rounded() }
    public init(jsTime: Double) { self.init(timeIntervalSince1970: jsTime / 1000) }
}
