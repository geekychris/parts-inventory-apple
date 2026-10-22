import Foundation
import PartsKit
import SwiftData

/// The inventory for other tools: the operations behind the REST API and the MCP tools, run on the main actor
/// against the app's own store (so changes show up in the windows straight away). Parts are shaped like the
/// web version's backup file (`Backup.Part`, ids are the `uid`s) with a few extras: `locationPath`,
/// `photoCount`, `isLow` and `summary`.
@MainActor
final class InventoryAPI {
    let container: ModelContainer
    var ctx: ModelContext { container.mainContext }
    /// The supplier lookup to use (Settings' keys unless a test swaps it).
    var lookup: () -> SupplierLookup = { SupplierKeys.shared.lookup }

    init(container: ModelContainer) { self.container = container }

    struct Failure: Error { let status: Int; let message: String }
    static func fail(_ status: Int, _ message: String) -> Failure { Failure(status: status, message: message) }

    var defaultLow: Int { UserDefaults.standard.integer(forKey: "defaultLowStock") }
    func save() { try? ctx.save() }

    // MARK: Shapes

    func partJSON(_ p: Part, brief: Bool = false) -> JSONValue {
        if brief {
            return .object(["id": .string(p.uid), "mpn": .string(p.mpn), "manufacturer": .string(p.manufacturer), "description": .string(p.partDescription),
                            "qty": .number(Double(p.qty)), "locationPath": .string(p.location?.path ?? ""), "summary": .string(p.paramsSummary),
                            "isLow": .bool(p.isLow(defaultLimit: defaultLow))])
        }
        guard case .object(var o) = JSONValue.from(Inventory.backupPart(p)) else { return .null }
        o["locationPath"] = .string(p.location?.path ?? "")
        o["photoCount"] = .number(Double(p.photos?.count ?? 0))
        o["isLow"] = .bool(p.isLow(defaultLimit: defaultLow))
        o["summary"] = .string(p.paramsSummary)
        return .object(o)
    }

    func locationJSON(_ l: StorageLocation) -> JSONValue {
        .object(["id": .string(l.uid), "parentId": l.parent.map { .string($0.uid) } ?? .null, "name": .string(l.name), "path": .string(l.path),
                 "notes": .string(l.notes), "parts": .number(Double(l.parts?.count ?? 0)), "partsBelow": .number(Double(l.partCount))])
    }

    nonisolated static func productJSON(_ p: SupplierProduct) -> JSONValue {
        .object([
            "supplier": .string(p.supplier), "supplierName": .string(p.supplierName), "spn": .string(p.spn), "mpn": .string(p.mpn),
            "manufacturer": .string(p.manufacturer), "description": .string(p.description), "detail": .string(p.detail),
            "datasheet": .string(p.datasheet), "url": .string(p.url), "image": .string(p.image),
            "stock": p.stock.map { .number(Double($0)) } ?? .null, "package": .string(p.package), "category": .string(p.category), "status": .string(p.status),
            "prices": .array(p.prices.map { .object(["qty": .number(Double($0.qty)), "unit": .number($0.unit), "currency": .string($0.currency)]) }),
            "parameters": .array(p.parameters.map { .object(["name": .string($0.name), "value": .string($0.value)]) }),
        ])
    }

    // MARK: Parts

    func part(_ uid: String) throws -> Part {
        guard let p = Inventory.allParts(ctx).first(where: { $0.uid == uid }) else { throw Self.fail(404, "No part with id \(uid).") }
        return p
    }

    struct Page { var total: Int; var parts: [Part] }

    func search(q: String = "", category: String = "", location: String = "", lowOnly: Bool = false, limit: Int = 100, offset: Int = 0) -> Page {
        let query = PartQuery(q)
        let cat = category.lowercased(), loc = location.lowercased()
        let hits = Inventory.allParts(ctx).filter { p in
            (query.isEmpty || p.matches(query, defaultLow: defaultLow))
                && (cat.isEmpty || p.category.lowercased().contains(cat))
                && (loc.isEmpty || (p.location?.path.lowercased().contains(loc) ?? false))
                && (!lowOnly || p.isLow(defaultLimit: defaultLow))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let start = min(max(0, offset), hits.count)
        return Page(total: hits.count, parts: Array(hits[start..<min(hits.count, start + max(0, min(limit, 1000)))]))
    }

    /// Set the fields given in `f` (missing keys are left alone). `qty` isn't here: stock changes go through `stock`.
    func apply(_ f: [String: JSONValue], to p: Part) throws {
        func text(_ k: String) -> String? { f[k].flatMap { $0.isNull ? "" : $0.string } }
        if let v = text("mpn") { p.mpn = v.trimmed }
        if let v = text("manufacturer") { p.manufacturer = v.trimmed }
        if let v = text("description") { p.partDescription = v }
        if let v = text("category") { p.category = v }
        if let v = text("package") { p.package = v }
        if let v = text("datasheet") { p.datasheet = v }
        if let v = text("image") { p.imageURL = v }
        if let v = text("notes") { p.notes = v }
        if let v = f["lowStock"] { p.lowStock = v.isNull ? nil : v.int }
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
            if v.isNull || v.string == "" { p.location = nil }
            else if let id = v.string {
                guard let l = ((try? ctx.fetch(FetchDescriptor<StorageLocation>())) ?? []).first(where: { $0.uid == id }) else { throw Self.fail(400, "No location with id \(id).") }
                p.location = l
            }
        }
        if let v = text("location") { p.location = v.trimmed.isEmpty ? nil : Inventory.ensureLocation(v, in: ctx) }
        p.updated = .now
    }

    struct LookupNote { var used: [SupplierProduct] = []; var errors: [String: String] = [:]; var tried = false }

    /// A new part. With `lookup`, its number is looked up at Digi-Key and Mouser and the empty fields are filled in.
    func create(_ f: [String: JSONValue], lookup doLookup: Bool) async throws -> (Part, LookupNote) {
        let mpn = f["mpn"]?.string?.trimmed ?? ""
        guard !mpn.isEmpty || !(f["description"]?.string ?? "").isEmpty else { throw Self.fail(400, "A new part needs an mpn or a description.") }
        var note = LookupNote()
        var found: [SupplierProduct] = []
        if doLookup, !mpn.isEmpty {
            let l = lookup()
            if l.isConfigured {
                note.tried = true
                let r = await l.lookup(mpn)
                note.errors = r.errors
                found = Self.sameMPN(r.products, mpn)
            } else {
                note.errors["suppliers"] = "No supplier keys: add them in Settings › Supplier lookups."
            }
        }
        let p = Part()
        ctx.insert(p)
        try apply(f, to: p)
        for s in found { Inventory.fill(p, from: s) }
        note.used = found
        if let b64 = f["photo"]?.string, let d = Data(base64Encoded: b64.replacingOccurrences(of: "^data:[^,]*,", with: "", options: .regularExpression)) {
            let ph = PartPhoto(data: Images.jpeg(d, maxSide: 2048) ?? d)
            ctx.insert(ph); ph.part = p
        }
        let qty = f["qty"]?.int ?? 0
        if qty > 0 { Inventory.adjust(p, by: qty, reason: f["reason"]?.string ?? "Added through the API", in: ctx) }
        save()
        return (p, note)
    }

    /// The best listing for a number and its twin at the other supplier (same MPN and maker).
    nonisolated static func sameMPN(_ products: [SupplierProduct], _ mpn: String) -> [SupplierProduct] {
        func key(_ s: String) -> String { s.uppercased().filter { $0.isLetter || $0.isNumber } }
        let exact = products.filter { key($0.mpn) == key(mpn) }
        guard let best = exact.first ?? products.first else { return [] }
        let twin = products.first { $0.supplier != best.supplier && key($0.mpn) == key(best.mpn) && $0.manufacturer.lowercased().prefix(4) == best.manufacturer.lowercased().prefix(4) }
        return [best] + (twin.map { [$0] } ?? [])
    }

    func update(_ uid: String, _ f: [String: JSONValue]) throws -> Part {
        let p = try part(uid)
        try apply(f, to: p)
        if let q = f["qty"]?.int, q != p.qty { Inventory.setQty(p, to: q, reason: f["reason"]?.string ?? "Set through the API", in: ctx) }
        save()
        return p
    }

    func delete(_ uid: String) throws -> String {
        let p = try part(uid)
        let title = p.title
        ctx.delete(p)
        save()
        return title
    }

    /// Change stock by `delta`, or `set` it, recording why.
    func stock(_ uid: String, delta: Int?, set: Int?, note: String) throws -> (Part, Int) {
        let p = try part(uid)
        let before = p.qty
        let why = note.trimmed.isEmpty ? "API" : "API — \(note.trimmed)"
        if let set { guard set >= 0 else { throw Self.fail(400, "set can't be negative.") }; Inventory.setQty(p, to: set, reason: why, in: ctx) }
        else if let delta { Inventory.adjust(p, by: delta, reason: why, in: ctx) }
        else { throw Self.fail(400, "Send {\"delta\": n} or {\"set\": n}.") }
        save()
        return (p, p.qty - before)
    }

    func history(_ p: Part, limit: Int = 20) -> JSONValue {
        .array((p.history ?? []).sorted { $0.at > $1.at }.prefix(limit).map { c in
            .object(["at": .string(ISO8601DateFormatter().string(from: c.at)), "delta": .number(Double(c.delta)),
                     "qtyAfter": c.qtyAfter.map { .number(Double($0)) } ?? .null, "reason": .string(c.reason)])
        })
    }

    // MARK: Locations and projects

    func locations() -> [StorageLocation] {
        ((try? ctx.fetch(FetchDescriptor<StorageLocation>())) ?? []).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func addLocation(_ path: String) throws -> StorageLocation {
        guard let l = Inventory.ensureLocation(path, in: ctx) else { throw Self.fail(400, "Give a path like “Cabinet A / Drawer 3”.") }
        save()
        return l
    }

    func projects() -> [Project] { ((try? ctx.fetch(FetchDescriptor<Project>())) ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    func projectJSON(_ pr: Project, lines: Bool) -> JSONValue {
        let parts = Inventory.allParts(ctx)
        let rows = pr.lines.map { ln -> (Backup.Project.Line, Part?, Int) in
            (ln, BOM.match(ln, in: parts), ln.dnp ? 0 : Int((ln.qty * pr.boards).rounded(.up)))
        }
        let counted = rows.filter { $0.0.qty > 0 && !$0.0.dnp }
        let canBuild = counted.isEmpty ? 0 : counted.map { r in r.1.map { Int(Double($0.qty) / r.0.qty) } ?? 0 }.min() ?? 0
        var o: [String: JSONValue] = ["id": .string(pr.uid), "name": .string(pr.name), "notes": .string(pr.notes), "boards": .number(pr.boards),
                                      "lineCount": .number(Double(pr.lines.count)), "canBuild": .number(Double(canBuild)),
                                      "short": .number(Double(rows.filter { $0.2 > ($0.1?.qty ?? 0) }.count))]
        if lines {
            o["lines"] = .array(rows.map { ln, p, need in
                .object(["refs": .array(ln.refs.map(JSONValue.string)), "qty": .number(ln.qty), "value": .string(ln.value), "footprint": .string(ln.footprint),
                         "mpn": .string(ln.mpn), "manufacturer": .string(ln.manufacturer), "description": .string(ln.description), "dnp": .bool(ln.dnp),
                         "need": .number(Double(need)), "have": .number(Double(p?.qty ?? 0)), "partId": p.map { .string($0.uid) } ?? .null,
                         "partMpn": .string(p?.mpn ?? ""), "location": .string(p?.location?.path ?? "")])
            })
        }
        return .object(o)
    }

    // MARK: Suppliers, photos, backups

    func supplierLookup(_ q: String) async throws -> SupplierLookup.Result {
        guard !q.trimmed.isEmpty else { throw Self.fail(400, "Give a part number to look up (q).") }
        let l = lookup()
        guard l.isConfigured else { throw Self.fail(409, "No supplier keys yet: add Digi-Key and/or Mouser keys in Settings › Supplier lookups.") }
        return await l.lookup(q.trimmed)
    }

    nonisolated static func lookupJSON(_ r: SupplierLookup.Result, limit: Int = 20) -> JSONValue {
        .object(["results": .array(r.products.prefix(limit).map { productJSON($0) }), "count": .number(Double(r.products.count)),
                 "errors": .object(r.errors.mapValues(JSONValue.string))])
    }

    /// What Identify makes of a photo: markings, any bag label, and the ranked candidates.
    func identify(_ image: Data) async throws -> JSONValue {
        let m = IdentifyModel()
        m.set(image)
        if let e = m.error { throw Self.fail(415, e) }
        await m.identify(inventory: Inventory.allParts(ctx).map(\.inventoryRef), lookWhen: .auto, useAI: true)
        var o: [String: JSONValue] = ["markings": .string(m.markings), "barcodes": .array(m.reading.barcodes.map(JSONValue.string)),
                                      "candidates": .array(m.candidates.prefix(8).map { Self.candidateJSON($0) })]
        if let e = m.error { o["warning"] = .string(e) }
        if let l = m.label {
            o["bagLabel"] = .object(["supplier": .string(l.supplier ?? ""), "mpn": .string(l.mpn), "spn": .string(l.spn),
                                     "manufacturer": .string(l.manufacturer), "qty": l.qty.map { .number(Double($0)) } ?? .null])
        }
        return .object(o)
    }

    nonisolated static func candidateJSON(_ c: Candidate) -> JSONValue {
        var o: [String: JSONValue] = ["score": .number((c.score * 100).rounded() / 100), "confidence": .string(c.confidence),
                                      "byLook": .bool(c.byLook), "reasons": .array(c.reasons.map(JSONValue.string))]
        switch c.source {
        case .catalog(let e):
            o["kind"] = .string("catalog"); o["name"] = .string(e.displayName); o["mpn"] = .string(e.mpn); o["manufacturer"] = .string(e.mfr)
            o["description"] = .string(e.desc); o["category"] = .string(e.cat); o["datasheet"] = .string(e.ds ?? "")
        case .inventory(let r):
            o["kind"] = .string("inventory"); o["partId"] = .string(r.id); o["mpn"] = .string(r.mpn); o["name"] = .string(r.mpn)
        case .generic(let g):
            o["kind"] = .string("generic"); o["name"] = .string(g.name); o["category"] = .string(g.cat)
        case .unknown(let t):
            o["kind"] = .string("unknown"); o["name"] = .string(t); o["mpn"] = .string(t)
        case .reading(let r):
            o["kind"] = .string("reading"); o["name"] = .string(r.mpn); o["mpn"] = .string(r.mpn); o["manufacturer"] = .string(r.manufacturer)
            o["description"] = .string(r.description); o["category"] = .string(r.category)
        }
        return .object(o)
    }

    func photo(_ uid: String, index: Int) throws -> (Data, String) {
        let photos = try part(uid).sortedPhotos
        guard photos.indices.contains(index), let d = photos[index].data else { throw Self.fail(404, "That part has \(photos.count) photo(s); index \(index) isn't one.") }
        return (d, photos[index].type)
    }

    func export(photos: Bool) throws -> Data { try Inventory.backup(in: ctx, photos: photos).encoded() }

    func importBackup(_ data: Data) throws -> Inventory.ImportResult {
        do {
            let (b, warnings) = try Backup.read(data)
            return Inventory.merge(b, warnings: warnings, in: ctx)
        } catch { throw Self.fail(400, error.localizedDescription) }
    }
}

/// A BOM line's part: linked, by part number, or by value and package.
enum BOM {
    static func match(_ ln: Backup.Project.Line, in parts: [Part]) -> Part? {
        if let id = ln.partId, let p = parts.first(where: { $0.uid == id }) { return p }
        let n = Identify.squash(ln.mpn)
        if !n.isEmpty, let p = parts.first(where: { Identify.squash($0.mpn) == n || $0.suppliers.contains { Identify.squash($0.pn) == n } }) { return p }
        guard ln.params.value != nil else { return nil }
        var q = PartQuery("")
        q.value = ln.params.value; q.kind = ln.params.kind; q.pkg = ln.params.pkg
        return parts.filter { q.matches($0.params.withPackage($0.package)) }.max { $0.qty < $1.qty }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
