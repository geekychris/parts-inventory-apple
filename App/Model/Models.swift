import Foundation
import SwiftData
import PartsKit

// The inventory, stored with SwiftData and synced through the user's private iCloud database.
// CloudKit's rules: every property has a default, every relationship is optional, nothing is
// unique. `uid` keeps the web tool's ids, so a backup goes back and forth between the two.

@Model
final class Part {
    var uid: String = ""
    var mpn: String = ""
    var manufacturer: String = ""
    var partDescription: String = ""
    /// "Passives/Resistors" (shown "Passives › Resistors").
    var category: String = ""
    var package: String = ""
    var qty: Int = 0
    var lowStock: Int?
    var datasheet: String = ""
    var imageURL: String = ""
    var notes: String = ""
    var created: Date = Date.now
    var updated: Date = Date.now
    // Codable values as JSON, so CloudKit stores them as plain fields.
    var paramsJSON: String = "{}"
    var suppliersJSON: String = "[]"
    var pricesJSON: String = "[]"
    var tagsJSON: String = "[]"

    @Relationship(inverse: \StorageLocation.parts) var location: StorageLocation?
    @Relationship(deleteRule: .cascade, inverse: \PartPhoto.part) var photos: [PartPhoto]? = []
    @Relationship(deleteRule: .nullify, inverse: \StockChange.part) var history: [StockChange]? = []

    init(uid: String = IDs.make("p")) { self.uid = uid }

    var params: PartParams {
        get { JSONField.decode(paramsJSON) ?? PartParams() }
        set { paramsJSON = JSONField.encode(newValue) }
    }
    var suppliers: [SupplierEntry] {
        get { JSONField.decode(suppliersJSON) ?? [] }
        set { suppliersJSON = JSONField.encode(newValue) }
    }
    var prices: [PricePaid] {
        get { JSONField.decode(pricesJSON) ?? [] }
        set { pricesJSON = JSONField.encode(newValue) }
    }
    var tags: [String] {
        get { JSONField.decode(tagsJSON) ?? [] }
        set { tagsJSON = JSONField.encode(newValue) }
    }

    /// What to call it in a list: the MPN, else the description.
    var title: String { !mpn.isEmpty ? mpn : !partDescription.isEmpty ? partDescription : "Unnamed part" }
    var categoryLabel: String { category.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " › ") }
    var paramsSummary: String { Values.summary(params) }
    var sortedPhotos: [PartPhoto] { (photos ?? []).sorted { $0.created < $1.created } }

    /// Every word searched by a text query.
    var searchText: String {
        ([mpn, manufacturer, partDescription, category, package, notes, location?.path ?? ""] + tags + suppliers.map(\.pn)).joined(separator: " ").lowercased()
    }

    func isLow(defaultLimit: Int) -> Bool {
        let lim = lowStock ?? defaultLimit
        return lim > 0 && qty <= lim
    }

    func matches(_ q: PartQuery, defaultLow: Int = 0) -> Bool {
        if q.hasParams && !q.matches(params.withPackage(package)) { return false }
        let hay = searchText
        if !q.text.allSatisfy(hay.contains) { return false }
        if let c = q.category, !category.lowercased().contains(c) { return false }
        if let l = q.location, !(location?.path.lowercased().contains(l) ?? false) { return false }
        if let t = q.tag, !tags.contains(where: { $0.lowercased() == t }) { return false }
        if let m = q.manufacturer, !manufacturer.lowercased().contains(m) { return false }
        if q.lowOnly && !isLow(defaultLimit: defaultLow) { return false }
        return true
    }

    var inventoryRef: InventoryRef { InventoryRef(id: uid, mpn: mpn, supplierPNs: suppliers.map(\.pn)) }
}

nonisolated extension PartParams {
    /// The package field fills in for a missing pkg parameter, for searching.
    func withPackage(_ package: String) -> PartParams {
        var p = self
        if p.pkg == nil || p.pkg!.isEmpty, !package.isEmpty { p.pkg = Values.normPackage(package).isEmpty ? package : Values.normPackage(package) }
        return p
    }
}

@Model
final class StorageLocation {
    var uid: String = ""
    var name: String = ""
    var notes: String = ""
    var order: Double = 0
    var created: Date = Date.now
    var updated: Date = Date.now
    @Relationship(inverse: \StorageLocation.children) var parent: StorageLocation?
    var children: [StorageLocation]? = []
    var parts: [Part]? = []

    init(uid: String = IDs.make("l"), name: String, parent: StorageLocation? = nil) {
        self.uid = uid; self.name = name; self.parent = parent
    }

    /// "Cabinet A › Drawer 3 › Bin 2".
    var path: String {
        var names: [String] = [], seen = Set<String>()
        var l: StorageLocation? = self
        while let x = l, !seen.contains(x.uid) { seen.insert(x.uid); names.insert(x.name, at: 0); l = x.parent }
        return names.joined(separator: " › ")
    }
    var sortedChildren: [StorageLocation]? {
        let c = (children ?? []).sorted { ($0.order, $0.name) < ($1.order, $1.name) }
        return c.isEmpty ? nil : c
    }
    /// Units stored here and below.
    var partCount: Int { (parts ?? []).count + (children ?? []).reduce(0) { $0 + $1.partCount } }
}

/// A photo of a part. The image data goes to iCloud as an asset.
@Model
final class PartPhoto {
    var uid: String = ""
    var name: String = ""
    var type: String = "image/jpeg"
    @Attribute(.externalStorage) var data: Data?
    var created: Date = Date.now
    var updated: Date = Date.now
    var part: Part?

    init(uid: String = IDs.make("ph"), data: Data, type: String = "image/jpeg", name: String = "") {
        self.uid = uid; self.data = data; self.type = type; self.name = name
    }
}

/// A change in stock, and why.
@Model
final class StockChange {
    var uid: String = ""
    var at: Date = Date.now
    var partUID: String = ""
    var delta: Int = 0
    var qtyAfter: Int?
    var reason: String = ""
    var supplier: String?
    var lot: String?
    var part: Part?

    init(uid: String = IDs.make("h"), part: Part?, delta: Int, reason: String, at: Date = .now) {
        self.uid = uid; self.part = part; self.partUID = part?.uid ?? ""; self.delta = delta; self.reason = reason; self.at = at
        self.qtyAfter = part?.qty
    }
}

/// A project's bill of materials. The app shows it against stock; the web tool plans builds and orders.
@Model
final class Project {
    var uid: String = ""
    var name: String = ""
    var notes: String = ""
    var boards: Double = 1
    var attritionPct: Double?
    var minExtra: Double?
    var linesJSON: String = "[]"
    var reservedJSON: String = "{}"
    var buildsJSON: String = "[]"
    var created: Date = Date.now
    var updated: Date = Date.now

    init(uid: String = IDs.make("pr"), name: String) { self.uid = uid; self.name = name }

    var lines: [Backup.Project.Line] {
        get { JSONField.decode(linesJSON) ?? [] }
        set { linesJSON = JSONField.encode(newValue) }
    }
    var reserved: [String: Double] {
        get { JSONField.decode(reservedJSON) ?? [:] }
        set { reservedJSON = JSONField.encode(newValue) }
    }
}

nonisolated enum JSONField {
    static func decode<T: Decodable>(_ s: String) -> T? { try? JSONDecoder().decode(T.self, from: Data(s.utf8)) }
    static func encode<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

enum Schema1 {
    static let models: [any PersistentModel.Type] = [Part.self, StorageLocation.self, PartPhoto.self, StockChange.self, Project.self]
}
