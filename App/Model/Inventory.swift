import Foundation
import SwiftData
import PartsKit

/// Changes to the inventory that touch more than one record: stock with history, receiving a bag,
/// adding an identified part, and the web tool's backup file both ways.
@MainActor
enum Inventory {
    static func allParts(_ ctx: ModelContext) -> [Part] { (try? ctx.fetch(FetchDescriptor<Part>())) ?? [] }

    /// Change a part's quantity and record why.
    @discardableResult
    static func adjust(_ part: Part, by delta: Int, reason: String, in ctx: ModelContext, supplier: String? = nil, lot: String? = nil) -> StockChange? {
        guard delta != 0 else { return nil }
        part.qty = max(0, part.qty + delta)
        part.updated = .now
        let c = StockChange(part: part, delta: delta, reason: reason)
        c.supplier = supplier; c.lot = lot
        ctx.insert(c)
        return c
    }

    static func setQty(_ part: Part, to qty: Int, reason: String = "Stock count", in ctx: ModelContext) {
        adjust(part, by: max(0, qty) - part.qty, reason: reason, in: ctx)
    }

    static func norm(_ s: String) -> String { s.uppercased().replacingOccurrences(of: " ", with: "") }

    /// Find a part by a supplier part number or an MPN.
    static func find(spn: String = "", supplier: String? = nil, mpn: String = "", manufacturer: String = "", in ctx: ModelContext) -> Part? {
        let parts = allParts(ctx)
        if !spn.isEmpty {
            let n = norm(spn)
            if let hit = parts.first(where: { $0.suppliers.contains { norm($0.pn) == n && (supplier == nil || $0.supplier == supplier) } })
                ?? parts.first(where: { $0.suppliers.contains { norm($0.pn) == n } }) { return hit }
        }
        if !mpn.isEmpty {
            let n = norm(mpn)
            let hits = parts.filter { norm($0.mpn) == n }
            if hits.count > 1, !manufacturer.isEmpty, let m = hits.first(where: { $0.manufacturer.lowercased() == manufacturer.lowercased() }) { return m }
            return hits.first
        }
        return nil
    }

    /// Bring a scanned bag into stock: a matching part gets the quantity added; otherwise a new part.
    @discardableResult
    static func receive(_ label: BagLabel, qty: Int? = nil, location: StorageLocation? = nil, in ctx: ModelContext) -> (part: Part, isNew: Bool)? {
        guard label.hasPart else { return nil }
        let q = qty ?? label.qty ?? 0
        var part = find(spn: label.spn, supplier: label.supplier, mpn: label.mpn, manufacturer: label.manufacturer, in: ctx)
        let isNew = part == nil
        if part == nil {
            let p = Part()
            p.mpn = label.mpn.isEmpty ? label.spn : label.mpn
            p.manufacturer = label.manufacturer
            let params = Values.params(from: label.mpn)
            p.params = params
            p.package = params.pkg ?? ""
            p.location = location
            p.tags = ["scanned"]
            ctx.insert(p)
            part = p
        }
        let p = part!
        if p.mpn.isEmpty && !label.mpn.isEmpty { p.mpn = label.mpn }
        if let s = label.supplier, !label.spn.isEmpty, !p.suppliers.contains(where: { $0.supplier == s && norm($0.pn) == norm(label.spn) }) {
            var list = p.suppliers
            list.append(SupplierEntry(supplier: s, pn: label.spn))
            p.suppliers = list
        }
        let what = [Supplier.named(label.supplier ?? "")?.name, label.salesOrder.isEmpty ? nil : "order \(label.salesOrder)"].compactMap { $0 }.joined(separator: " ")
        if q > 0 { adjust(p, by: q, reason: what.isEmpty ? "Scanned bag" : "Scanned bag — \(what)", in: ctx, supplier: label.supplier, lot: label.lot.isEmpty ? nil : label.lot) }
        p.updated = .now
        return (p, isNew)
    }

    /// A new part from an identified candidate, with the photo it came from.
    static func add(_ d: PartDraft, photo: Data?, location: StorageLocation?, in ctx: ModelContext) -> Part {
        let p = Part()
        p.mpn = d.mpn; p.manufacturer = d.manufacturer; p.partDescription = d.description; p.category = d.category; p.package = d.package
        p.datasheet = d.datasheet; p.params = d.params; p.tags = d.tags; p.notes = d.notes; p.location = location
        ctx.insert(p)
        if let photo {
            let ph = PartPhoto(data: photo)
            ctx.insert(ph)
            ph.part = p
        }
        adjust(p, by: d.qty, reason: "Identified from a photo", in: ctx)
        return p
    }

    /// Find or make "Cabinet A › Drawer 3" (also "Cabinet A/Drawer 3"); returns the leaf.
    static func ensureLocation(_ path: String, in ctx: ModelContext) -> StorageLocation? {
        let segs = path.split(whereSeparator: { "/›>".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let all = (try? ctx.fetch(FetchDescriptor<StorageLocation>())) ?? []
        var parent: StorageLocation?
        for name in segs {
            if let l = all.first(where: { $0.parent?.uid == parent?.uid && $0.name.lowercased() == name.lowercased() }) { parent = l; continue }
            let l = StorageLocation(name: name, parent: parent)
            ctx.insert(l)
            parent = l
        }
        return parent
    }

    // ------------------------------------------------------------ the web tool's backup file
    struct ImportResult { var added = 0, updated = 0, kept = 0, photos = 0; var warnings: [String] = [] }

    /// Merge a backup by id: new items are added, items in both take the newer `updated`. Nothing is deleted.
    static func merge(_ b: Backup, warnings: [String] = [], in ctx: ModelContext) -> ImportResult {
        var r = ImportResult(warnings: warnings)
        let locs = (try? ctx.fetch(FetchDescriptor<StorageLocation>())) ?? []
        var locByUID = Dictionary(locs.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        for x in b.locations {
            let incoming = Date(jsTime: x.updated)
            if let l = locByUID[x.id] {
                guard incoming > l.updated else { r.kept += 1; continue }
                l.name = x.name; l.notes = x.notes; l.order = x.order; l.updated = incoming; r.updated += 1
            } else {
                let l = StorageLocation(uid: x.id, name: x.name)
                l.notes = x.notes; l.order = x.order; l.created = Date(jsTime: x.created); l.updated = incoming
                ctx.insert(l); locByUID[x.id] = l; r.added += 1
            }
        }
        for x in b.locations { if let l = locByUID[x.id] { l.parent = x.parentId.flatMap { locByUID[$0] } } }

        var partByUID = Dictionary(allParts(ctx).map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        for x in b.parts {
            let incoming = Date(jsTime: x.updated)
            let p: Part
            if let existing = partByUID[x.id] {
                guard incoming > existing.updated else { r.kept += 1; continue }
                p = existing; r.updated += 1
            } else {
                p = Part(uid: x.id); ctx.insert(p); partByUID[x.id] = p; r.added += 1
                p.created = Date(jsTime: x.created)
            }
            p.mpn = x.mpn; p.manufacturer = x.manufacturer; p.partDescription = x.description; p.category = x.category; p.package = x.package
            p.params = x.params; p.qty = Int(x.qty); p.suppliers = x.suppliers; p.prices = x.prices; p.datasheet = x.datasheet
            p.imageURL = x.image; p.notes = x.notes; p.lowStock = x.lowStock.map(Int.init); p.tags = x.tags; p.updated = incoming
            p.location = x.locationId.flatMap { locByUID[$0] }
        }
        let haveChanges = Set(((try? ctx.fetch(FetchDescriptor<StockChange>())) ?? []).map(\.uid))
        for x in b.history where !haveChanges.contains(x.id) {
            let c = StockChange(uid: x.id, part: x.partId.flatMap { partByUID[$0] }, delta: Int(x.delta), reason: x.reason, at: Date(jsTime: x.at))
            c.partUID = x.partId ?? ""; c.qtyAfter = x.qtyAfter.map(Int.init); c.supplier = x.supplier; c.lot = x.lot
            ctx.insert(c)
        }
        let projects = Dictionary(((try? ctx.fetch(FetchDescriptor<Project>())) ?? []).map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        for x in b.projects {
            let incoming = Date(jsTime: x.updated)
            let pr: Project
            if let e = projects[x.id] { guard incoming > e.updated else { r.kept += 1; continue }; pr = e; r.updated += 1 }
            else { pr = Project(uid: x.id, name: x.name); ctx.insert(pr); pr.created = Date(jsTime: x.created); r.added += 1 }
            pr.name = x.name; pr.notes = x.notes; pr.boards = x.boards; pr.attritionPct = x.attritionPct; pr.minExtra = x.minExtra
            pr.lines = x.lines; pr.reserved = x.reserved; pr.buildsJSON = JSONField.encode(x.builds); pr.updated = incoming
        }
        let havePhotos = Set(((try? ctx.fetch(FetchDescriptor<PartPhoto>())) ?? []).map(\.uid))
        for x in b.photos ?? [] where !havePhotos.contains(x.id) {
            guard let data = Data(base64Encoded: x.data.replacingOccurrences(of: "^data:[^,]*,", with: "", options: .regularExpression)) else { continue }
            let ph = PartPhoto(uid: x.id, data: data, type: x.type ?? "image/jpeg", name: x.name ?? "")
            ctx.insert(ph)
            ph.part = x.partId.flatMap { partByUID[$0] }
            r.photos += 1
        }
        try? ctx.save()
        return r
    }

    /// The whole inventory as the web tool's backup file.
    static func backup(in ctx: ModelContext, photos includePhotos: Bool) -> Backup {
        var b = Backup()
        b.exportedAt = ISO8601DateFormatter().string(from: .now)
        b.app = "Parts Inventory for iOS and macOS"
        b.settings = ["currency": .string(UserDefaults.standard.string(forKey: "currency") ?? "USD"),
                      "defaultLowStock": .number(Double(UserDefaults.standard.integer(forKey: "defaultLowStock")))]
        let parts = allParts(ctx)
        b.parts = parts.map { p in
            var x = Backup.Part(id: p.uid)
            x.mpn = p.mpn; x.manufacturer = p.manufacturer; x.description = p.partDescription; x.category = p.category; x.package = p.package
            x.params = p.params; x.qty = Double(p.qty); x.locationId = p.location?.uid; x.suppliers = p.suppliers; x.prices = p.prices
            x.datasheet = p.datasheet; x.image = p.imageURL; x.notes = p.notes; x.photoIds = p.sortedPhotos.map(\.uid)
            x.lowStock = p.lowStock.map(Double.init); x.tags = p.tags; x.created = p.created.jsTime; x.updated = p.updated.jsTime
            return x
        }
        b.locations = ((try? ctx.fetch(FetchDescriptor<StorageLocation>())) ?? []).map { l in
            var x = Backup.Location(id: l.uid, parentId: l.parent?.uid, name: l.name)
            x.notes = l.notes; x.order = l.order; x.created = l.created.jsTime; x.updated = l.updated.jsTime
            return x
        }
        b.projects = ((try? ctx.fetch(FetchDescriptor<Project>())) ?? []).compactMap { pr in
            var o: [String: JSONValue] = ["id": .string(pr.uid), "name": .string(pr.name), "notes": .string(pr.notes), "boards": .number(pr.boards),
                                          "created": .number(pr.created.jsTime), "updated": .number(pr.updated.jsTime)]
            o["attritionPct"] = pr.attritionPct.map(JSONValue.number) ?? .null
            o["minExtra"] = pr.minExtra.map(JSONValue.number) ?? .null
            o["lines"] = JSONField.decode(pr.linesJSON) ?? .array([])
            o["reserved"] = JSONField.decode(pr.reservedJSON) ?? .object([:])
            o["builds"] = JSONField.decode(pr.buildsJSON) ?? .array([])
            return (try? JSONEncoder().encode(JSONValue.object(o))).flatMap { try? JSONDecoder().decode(Backup.Project.self, from: $0) }
        }
        b.history = ((try? ctx.fetch(FetchDescriptor<StockChange>(sortBy: [SortDescriptor(\.at)]))) ?? []).map { c in
            var x = Backup.Change(id: c.uid, at: c.at.jsTime, partId: c.part?.uid ?? c.partUID, delta: Double(c.delta), qtyAfter: c.qtyAfter.map(Double.init), reason: c.reason)
            x.supplier = c.supplier; x.lot = c.lot
            return x
        }
        if includePhotos {
            b.photos = parts.flatMap { p in p.sortedPhotos.compactMap { ph in
                ph.data.map { Backup.Photo(id: ph.uid, partId: p.uid, type: ph.type, name: ph.name, data: $0.base64EncodedString(), created: ph.created.jsTime, updated: ph.updated.jsTime) }
            } }
        }
        return b
    }
}
