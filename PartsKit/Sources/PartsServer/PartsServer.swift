import Foundation
import PartsKit

/// The inventory behind `partsd`'s REST API and MCP tools: the same operations and JSON shapes as the app's
/// `InventoryAPI`, over the backup format (`Backup`) kept in an `InventoryStore` instead of SwiftData. One actor,
/// so requests take turns; every change is saved before its response goes out.
public actor PartsServer {
    public struct Failure: Error, Sendable { public let status: Int; public let message: String }
    static func fail(_ status: Int, _ message: String) -> Failure { Failure(status: status, message: message) }

    public static let version = "0.1.0"

    let store: InventoryStore
    var b: Backup
    var photos: [InventoryStore.PhotoRecord]
    let lookup: SupplierLookup
    let identifier: Identifier?

    /// Photo identification without Apple's frameworks: a vision model reads the markings, and optionally a text
    /// model interprets them (see PhotoIdentify).
    public struct Identifier: Sendable {
        public var reader: OpenAICompatibleMarkingReader
        public var model: OpenAICompatibleModel?
        public init(reader: OpenAICompatibleMarkingReader, model: OpenAICompatibleModel? = nil) { self.reader = reader; self.model = model }
    }

    public init(dataDirectory: URL, lookup: SupplierLookup, identifier: Identifier? = nil) throws {
        store = try InventoryStore(dir: dataDirectory)
        (b, photos) = try store.load()
        self.lookup = lookup
        self.identifier = identifier
    }

    public var canIdentify: Bool { identifier != nil }

    public var partCount: Int { b.parts.count }

    var defaultLow: Int { b.settings["defaultLowStock"]?.int ?? 0 }

    func save() throws {
        do { try store.save(b, photos: photos) } catch { throw Self.fail(500, "Couldn’t save the inventory: \(error.localizedDescription)") }
    }

    // MARK: Lookups within the inventory

    func index(of uid: String) throws -> Int {
        guard let i = b.parts.firstIndex(where: { $0.id == uid }) else { throw Self.fail(404, "No part with id \(uid).") }
        return i
    }

    /// "Cabinet A › Drawer 3 › Bin 2".
    func path(_ locationId: String?) -> String {
        var names: [String] = [], seen = Set<String>(), id = locationId
        while let x = id, seen.insert(x).inserted, let l = b.locations.first(where: { $0.id == x }) { names.insert(l.name, at: 0); id = l.parentId }
        return names.joined(separator: " › ")
    }

    func isLow(_ p: Backup.Part) -> Bool {
        let lim = p.lowStock.map(Int.init) ?? defaultLow
        return lim > 0 && Int(p.qty) <= lim
    }

    static func title(_ p: Backup.Part) -> String { !p.mpn.isEmpty ? p.mpn : !p.description.isEmpty ? p.description : "Unnamed part" }

    // MARK: Shapes

    func partJSON(_ p: Backup.Part, brief: Bool = false) -> JSONValue {
        if brief {
            return .object(["id": .string(p.id), "mpn": .string(p.mpn), "manufacturer": .string(p.manufacturer), "description": .string(p.description),
                            "qty": .number(p.qty), "locationPath": .string(path(p.locationId)), "summary": .string(Values.summary(p.params)),
                            "isLow": .bool(isLow(p))])
        }
        guard case .object(var o) = JSONValue.from(p) else { return .null }
        o["locationPath"] = .string(path(p.locationId))
        o["photoCount"] = .number(Double(p.photoIds.count))
        o["isLow"] = .bool(isLow(p))
        o["summary"] = .string(Values.summary(p.params))
        return .object(o)
    }

    func locationJSON(_ l: Backup.Location) -> JSONValue {
        let here = b.parts.filter { $0.locationId == l.id }.count
        let below = b.parts.filter { p in
            var seen = Set<String>(), id = p.locationId
            while let x = id, seen.insert(x).inserted { if x == l.id { return true }; id = b.locations.first { $0.id == x }?.parentId }
            return false
        }.count
        return .object(["id": .string(l.id), "parentId": l.parentId.map { .string($0) } ?? .null, "name": .string(l.name), "path": .string(path(l.id)),
                        "notes": .string(l.notes), "parts": .number(Double(here)), "partsBelow": .number(Double(below))])
    }

    func history(_ uid: String, limit: Int = 20) -> JSONValue {
        .array(b.history.filter { $0.partId == uid }.sorted { $0.at > $1.at }.prefix(limit).map { c in
            .object(["at": .string(ISO8601DateFormatter().string(from: Date(jsTime: c.at))), "delta": .number(c.delta),
                     "qtyAfter": c.qtyAfter.map { .number($0) } ?? .null, "reason": .string(c.reason)])
        })
    }

    // MARK: Parts

    struct Page { var total: Int; var parts: [Backup.Part] }

    func search(q: String = "", category: String = "", location: String = "", lowOnly: Bool = false, limit: Int = 100, offset: Int = 0) -> Page {
        let query = PartQuery(q)
        let cat = category.lowercased(), loc = location.lowercased()
        let hits = b.parts.filter { p in
            let where_ = path(p.locationId)
            let text = ([p.mpn, p.manufacturer, p.description, p.category, p.package, p.notes, where_] + p.tags + p.suppliers.map(\.pn)).joined(separator: " ").lowercased()
            return (query.isEmpty || query.matches(params: p.params, package: p.package, text: text, category: p.category, location: where_,
                                                   tags: p.tags, manufacturer: p.manufacturer, isLow: isLow(p)))
                && (cat.isEmpty || p.category.lowercased().contains(cat))
                && (loc.isEmpty || where_.lowercased().contains(loc))
                && (!lowOnly || isLow(p))
        }.sorted { Self.title($0).localizedStandardCompare(Self.title($1)) == .orderedAscending }
        let start = min(max(0, offset), hits.count)
        return Page(total: hits.count, parts: Array(hits[start..<min(hits.count, start + max(0, min(limit, 1000)))]))
    }

    /// Set the fields given in `f` (missing keys are left alone). `qty` isn't here: stock changes go through `stock`.
    func apply(_ f: [String: JSONValue], to p: inout Backup.Part) throws {
        func text(_ k: String) -> String? { f[k].flatMap { $0.isNull ? "" : $0.string } }
        if let v = text("mpn") { p.mpn = v.trimmed }
        if let v = text("manufacturer") { p.manufacturer = v.trimmed }
        if let v = text("description") { p.description = v }
        if let v = text("category") { p.category = v }
        if let v = text("package") { p.package = v }
        if let v = text("datasheet") { p.datasheet = v }
        if let v = text("image") { p.image = v }
        if let v = text("notes") { p.notes = v }
        if let v = f["lowStock"] { p.lowStock = v.isNull ? nil : v.int.map(Double.init) }
        if let v = f["tags"] {
            p.tags = v.array?.compactMap(\.string) ?? (v.string ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let v = f["params"], !v.isNull {
            guard let params = v.decode(PartParams.self) else { throw Self.fail(400, "params isn't a parameter object ({kind, value, tol, voltage, power, dielectric, pkg}).") }
            p.params = params
        }
        if let v = text("paramsText"), !v.isEmpty { p.params = Values.params(from: v, kind: p.params.kind, footprint: p.package.isEmpty ? nil : p.package) }
        if let v = f["suppliers"], !v.isNull {
            guard let list = v.decode([SupplierEntry].self) else { throw Self.fail(400, "suppliers should be a list of {supplier, pn, …}.") }
            p.suppliers = list
        }
        if let v = f["locationId"] {
            if v.isNull || v.string == "" { p.locationId = nil }
            else if let id = v.string {
                guard b.locations.contains(where: { $0.id == id }) else { throw Self.fail(400, "No location with id \(id).") }
                p.locationId = id
            }
        }
        if let v = text("location") { p.locationId = v.trimmed.isEmpty ? nil : ensureLocation(v) }
        p.updated = Date.now.jsTime
    }

    /// Change a part's quantity and record why.
    func adjust(_ i: Int, by delta: Int, reason: String) {
        guard delta != 0 else { return }
        b.parts[i].qty = Double(max(0, Int(b.parts[i].qty) + delta))
        b.parts[i].updated = Date.now.jsTime
        b.history.append(Backup.Change(id: IDs.make("h"), at: Date.now.jsTime, partId: b.parts[i].id, delta: Double(delta), qtyAfter: b.parts[i].qty, reason: reason))
    }

    func setQty(_ i: Int, to qty: Int, reason: String) { adjust(i, by: max(0, qty) - Int(b.parts[i].qty), reason: reason) }

    /// Fill a part's empty fields from a supplier's listing, and add or refresh that supplier's number and prices.
    static func fill(_ part: inout Backup.Part, from p: SupplierProduct) {
        if part.mpn.isEmpty { part.mpn = p.mpn }
        if part.manufacturer.isEmpty { part.manufacturer = p.manufacturer }
        if part.description.isEmpty { part.description = p.description.isEmpty ? p.detail : p.description }
        if part.category.isEmpty { part.category = p.category }
        if part.package.isEmpty { part.package = p.normalisedPackage }
        if part.datasheet.isEmpty { part.datasheet = p.datasheet }
        if part.image.isEmpty { part.image = p.image }
        if Values.summary(part.params).isEmpty { part.params = p.params(kind: part.params.kind) }
        let e = p.supplierEntry()
        if let i = part.suppliers.firstIndex(where: { $0.supplier == e.supplier && $0.pn.caseInsensitiveCompare(e.pn) == .orderedSame }) { part.suppliers[i] = e }
        else { part.suppliers.append(e) }
        part.updated = Date.now.jsTime
    }

    struct LookupNote { var used: [SupplierProduct] = []; var errors: [String: String] = [:]; var tried = false }

    /// A new part. With `lookup`, its number is looked up at Digi-Key and Mouser and the empty fields are filled in.
    func create(_ f: [String: JSONValue], lookup doLookup: Bool) async throws -> (Backup.Part, LookupNote) {
        let mpn = f["mpn"]?.string?.trimmed ?? ""
        guard !mpn.isEmpty || !(f["description"]?.string ?? "").isEmpty else { throw Self.fail(400, "A new part needs an mpn or a description.") }
        var note = LookupNote()
        var found: [SupplierProduct] = []
        if doLookup, !mpn.isEmpty {
            if lookup.isConfigured {
                note.tried = true
                let r = await lookup.lookup(mpn)
                note.errors = r.errors
                found = InventoryCatalog.sameMPN(r.products, mpn)
            } else {
                note.errors["suppliers"] = "No supplier keys: start partsd with DIGIKEY_CLIENT_ID, DIGIKEY_CLIENT_SECRET and/or MOUSER_API_KEY set."
            }
        }
        var p = Backup.Part(id: IDs.make("p"))
        p.created = Date.now.jsTime
        try apply(f, to: &p)
        for s in found { Self.fill(&p, from: s) }
        note.used = found
        if let b64 = f["photo"]?.string, let d = Data(base64Encoded: b64.replacingOccurrences(of: "^data:[^,]*,", with: "", options: .regularExpression), options: .ignoreUnknownCharacters) {
            let id = IDs.make("ph")
            try store.writePhoto(id, d)
            photos.append(.init(id: id, partId: p.id, type: Self.imageType(d), name: "", created: Date.now.jsTime))
            p.photoIds.append(id)
        }
        b.parts.append(p)
        let qty = f["qty"]?.int ?? 0
        if qty > 0 { adjust(b.parts.count - 1, by: qty, reason: f["reason"]?.string ?? "Added through the API") }
        try save()
        return (b.parts[b.parts.count - 1], note)
    }

    func update(_ uid: String, _ f: [String: JSONValue]) throws -> Backup.Part {
        let i = try index(of: uid)
        // On a copy: apply reads the locations and may add some, which can't happen while b.parts[i] is lent out.
        var p = b.parts[i]
        try apply(f, to: &p)
        b.parts[i] = p
        if let q = f["qty"]?.int, q != Int(b.parts[i].qty) { setQty(i, to: q, reason: f["reason"]?.string ?? "Set through the API") }
        try save()
        return b.parts[i]
    }

    func delete(_ uid: String) throws -> String {
        let i = try index(of: uid)
        let p = b.parts.remove(at: i)
        for id in p.photoIds { store.deletePhoto(id) }
        photos.removeAll { $0.partId == uid }
        _ = b.repair()
        try save()
        return Self.title(p)
    }

    /// Change stock by `delta`, or `set` it, recording why.
    func stock(_ uid: String, delta: Int?, set: Int?, note: String) throws -> (Backup.Part, Int) {
        let i = try index(of: uid)
        let before = Int(b.parts[i].qty)
        let why = note.trimmed.isEmpty ? "API" : "API — \(note.trimmed)"
        if let set { guard set >= 0 else { throw Self.fail(400, "set can't be negative.") }; setQty(i, to: set, reason: why) }
        else if let delta { adjust(i, by: delta, reason: why) }
        else { throw Self.fail(400, "Send {\"delta\": n} or {\"set\": n}.") }
        try save()
        return (b.parts[i], Int(b.parts[i].qty) - before)
    }

    // MARK: Locations and projects

    func locations() -> [Backup.Location] { b.locations.sorted { path($0.id).localizedStandardCompare(path($1.id)) == .orderedAscending } }

    /// Find or make "Cabinet A › Drawer 3" (also "Cabinet A/Drawer 3"); returns the leaf's id.
    func ensureLocation(_ path: String) -> String? {
        let segs = path.split(whereSeparator: { "/›>".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var parent: String?
        for name in segs {
            if let l = b.locations.first(where: { $0.parentId == parent && $0.name.lowercased() == name.lowercased() }) { parent = l.id; continue }
            var l = Backup.Location(id: IDs.make("l"), parentId: parent, name: name)
            l.kind = LocationKind.guess(name: name)?.rawValue ?? ""
            l.created = Date.now.jsTime; l.updated = l.created
            b.locations.append(l)
            parent = l.id
        }
        return parent
    }

    func addLocation(_ path: String) throws -> Backup.Location {
        guard let id = ensureLocation(path), let l = b.locations.first(where: { $0.id == id }) else { throw Self.fail(400, "Give a path like “Cabinet A / Drawer 3”.") }
        try save()
        return l
    }

    func projects() -> [Backup.Project] { b.projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    /// A BOM line's part: linked, by part number, or by value and package (as the app's `BOM.match`).
    static func match(_ ln: Backup.Project.Line, in parts: [Backup.Part]) -> Backup.Part? {
        if let id = ln.partId, let p = parts.first(where: { $0.id == id }) { return p }
        let n = Identify.squash(ln.mpn)
        if !n.isEmpty, let p = parts.first(where: { Identify.squash($0.mpn) == n || $0.suppliers.contains { Identify.squash($0.pn) == n } }) { return p }
        guard ln.params.value != nil else { return nil }
        var q = PartQuery("")
        q.value = ln.params.value; q.kind = ln.params.kind; q.pkg = ln.params.pkg
        return parts.filter { q.matches($0.params.withPackage($0.package)) }.max { $0.qty < $1.qty }
    }

    func projectJSON(_ pr: Backup.Project, lines: Bool) -> JSONValue {
        let rows = pr.lines.map { ln -> (Backup.Project.Line, Backup.Part?, Int) in
            (ln, Self.match(ln, in: b.parts), ln.dnp ? 0 : Int((ln.qty * pr.boards).rounded(.up)))
        }
        let counted = rows.filter { $0.0.qty > 0 && !$0.0.dnp }
        let canBuild = counted.isEmpty ? 0 : counted.map { r in r.1.map { Int($0.qty / r.0.qty) } ?? 0 }.min() ?? 0
        var o: [String: JSONValue] = ["id": .string(pr.id), "name": .string(pr.name), "notes": .string(pr.notes), "boards": .number(pr.boards),
                                      "lineCount": .number(Double(pr.lines.count)), "canBuild": .number(Double(canBuild)),
                                      "short": .number(Double(rows.filter { Double($0.2) > ($0.1?.qty ?? 0) }.count))]
        if lines {
            o["lines"] = .array(rows.map { ln, p, need in
                .object(["refs": .array(ln.refs.map(JSONValue.string)), "qty": .number(ln.qty), "value": .string(ln.value), "footprint": .string(ln.footprint),
                         "mpn": .string(ln.mpn), "manufacturer": .string(ln.manufacturer), "description": .string(ln.description), "dnp": .bool(ln.dnp),
                         "need": .number(Double(need)), "have": .number(p?.qty ?? 0), "partId": p.map { .string($0.id) } ?? .null,
                         "partMpn": .string(p?.mpn ?? ""), "location": .string(path(p?.locationId))])
            })
        }
        return .object(o)
    }

    // MARK: Suppliers, photos, backups

    func supplierLookup(_ q: String) async throws -> SupplierLookup.Result {
        guard !q.trimmed.isEmpty else { throw Self.fail(400, "Give a part number to look up (q).") }
        guard lookup.isConfigured else { throw Self.fail(409, "No supplier keys: start partsd with DIGIKEY_CLIENT_ID, DIGIKEY_CLIENT_SECRET and/or MOUSER_API_KEY set.") }
        return await lookup.lookup(q.trimmed)
    }

    /// What the photo's markings say, matched against the built-in list and this inventory — the app's identify JSON.
    func identify(_ image: Data) async throws -> JSONValue {
        guard let identifier else { throw Self.fail(501, Self.identifyUnsupported) }
        let type = Self.imageType(image)
        guard type != "image/heic" else { throw Self.fail(415, "Send the photo as JPEG or PNG; HEIC isn't read here.") }
        let refs = b.parts.map { InventoryRef(id: $0.id, mpn: $0.mpn, supplierPNs: $0.suppliers.map(\.pn)) }
        let r: PhotoIdentify.Result
        do { r = try await PhotoIdentify.identify(image: image, type: type, inventory: refs, reader: identifier.reader, model: identifier.model) }
        catch { throw Self.fail(502, "Reading the photo failed: \(error.localizedDescription)") }
        var o: [String: JSONValue] = ["markings": .string(r.markings), "barcodes": .array([]),
                                      "candidates": .array(r.candidates.prefix(8).map { InventoryCatalog.candidateJSON($0) })]
        if let w = r.warning { o["warning"] = .string(w) }
        return .object(o)
    }

    func photo(_ uid: String, index: Int) throws -> (Data, String) {
        let p = b.parts[try self.index(of: uid)]
        guard p.photoIds.indices.contains(index), let d = store.readPhoto(p.photoIds[index]) else {
            throw Self.fail(404, "That part has \(p.photoIds.count) photo(s); index \(index) isn't one.")
        }
        return (d, photos.first { $0.id == p.photoIds[index] }?.type ?? Self.imageType(d))
    }

    static func imageType(_ d: Data) -> String {
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if d.count > 12, d[d.startIndex + 4..<d.startIndex + 12].elementsEqual("ftypheic".utf8) { return "image/heic" }
        return "image/jpeg"
    }

    func backup(photos withPhotos: Bool) -> Backup {
        var out = b
        out.exportedAt = ISO8601DateFormatter().string(from: .now)
        out.app = "e-Parts Inventory Manager — partsd \(Self.version)"
        if withPhotos {
            out.photos = photos.compactMap { r in
                store.readPhoto(r.id).map {
                    var x = Backup.Photo(id: r.id, partId: r.partId, type: r.type, name: r.name, data: $0.base64EncodedString(), created: r.created, updated: r.created)
                    x.locationId = r.locationId
                    return x
                }
            }
        }
        return out
    }

    struct ImportResult { var added = 0, updated = 0, kept = 0, photos = 0; var warnings: [String] = [] }

    /// Merge a backup by id, as the app does: new items are added, items in both take the newer `updated`. Nothing is deleted.
    func merge(_ x: Backup, warnings: [String]) throws -> ImportResult {
        var r = ImportResult(warnings: warnings)
        func upsert<T: Identifiable>(_ incoming: [T], into list: inout [T], updated: (T) -> Double, keep: (T, inout T) -> Void = { _, _ in }) where T.ID == String {
            for item in incoming {
                if let i = list.firstIndex(where: { $0.id == item.id }) {
                    guard updated(item) > updated(list[i]) else { r.kept += 1; continue }
                    var next = item
                    keep(list[i], &next)
                    list[i] = next; r.updated += 1
                } else { list.append(item); r.added += 1 }
            }
        }
        upsert(x.locations, into: &b.locations, updated: \.updated)
        // A part's photos are this server's files: keep the ones it has, whatever the incoming copy lists.
        upsert(x.parts, into: &b.parts, updated: \.updated) { old, new in new.photoIds = old.photoIds }
        for i in b.parts.indices { b.parts[i].photoIds.removeAll { id in !photos.contains { $0.id == id } } }
        upsert(x.projects, into: &b.projects, updated: \.updated)
        let have = Set(b.history.map(\.id))
        b.history += x.history.filter { !have.contains($0.id) }
        b.history.sort { $0.at < $1.at }
        if b.settings.isEmpty { b.settings = x.settings }
        for ph in x.photos ?? [] where !photos.contains(where: { $0.id == ph.id }) {
            guard let d = Data(base64Encoded: ph.data.replacingOccurrences(of: "^data:[^,]*,", with: "", options: .regularExpression), options: .ignoreUnknownCharacters) else { continue }
            if let pid = ph.partId, let i = b.parts.firstIndex(where: { $0.id == pid }) {
                b.parts[i].photoIds.append(ph.id)
            } else if ph.locationId.map({ lid in b.locations.contains { $0.id == lid } }) != true { continue }
            try store.writePhoto(ph.id, d)
            photos.append(.init(id: ph.id, partId: ph.partId, locationId: ph.locationId, type: ph.type ?? Self.imageType(d), name: ph.name ?? "", created: ph.created ?? Date.now.jsTime))
            r.photos += 1
        }
        r.warnings += b.repair()
        try save()
        return r
    }

    func importBackup(_ data: Data) throws -> ImportResult {
        let read: (backup: Backup, warnings: [String])
        do { read = try Backup.read(data) } catch { throw Self.fail(400, error.localizedDescription) }
        return try merge(read.backup, warnings: read.warnings)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
