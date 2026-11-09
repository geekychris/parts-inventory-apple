import Foundation
import PartsKit

// The edits the web pages make that the app's API doesn't have: a part's photos, filling a part in from a
// supplier listing, and changing or removing a location.

extension PartsServer {
    // MARK: Photos

    func addPhoto(_ uid: String, _ d: Data) throws -> Backup.Part {
        let i = try index(of: uid)
        let type = Self.imageType(d)
        guard type != "image/heic" else { throw Self.fail(415, "Send the photo as JPEG or PNG; HEIC isn't kept here.") }
        guard !d.isEmpty else { throw Self.fail(400, "The photo is empty.") }
        let id = IDs.make("ph")
        do { try store.writePhoto(id, d) } catch { throw Self.fail(500, "Couldn’t save the photo: \(error.localizedDescription)") }
        photos.append(.init(id: id, partId: uid, type: type, name: "", created: Date.now.jsTime))
        b.parts[i].photoIds.append(id)
        b.parts[i].updated = Date.now.jsTime
        try save()
        return b.parts[i]
    }

    func deletePhoto(_ uid: String, index n: Int) throws -> Backup.Part {
        let i = try index(of: uid)
        guard b.parts[i].photoIds.indices.contains(n) else { throw Self.fail(404, "That part has \(b.parts[i].photoIds.count) photo(s); index \(n) isn't one.") }
        let id = b.parts[i].photoIds.remove(at: n)
        store.deletePhoto(id)
        photos.removeAll { $0.id == id }
        b.parts[i].updated = Date.now.jsTime
        try save()
        return b.parts[i]
    }

    // MARK: Filling in from a supplier

    /// Look `query` (the part's number by default) up and fill the part's empty fields from the listing with
    /// supplier number `spn`, or from the best listing and its twin at the other supplier.
    func fill(_ uid: String, query: String?, supplier: String?, spn: String?) async throws -> (Backup.Part, [SupplierProduct]) {
        let p0 = b.parts[try index(of: uid)]
        let q = (query?.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? (p0.mpn.isEmpty ? p0.suppliers.first?.pn ?? "" : p0.mpn)
        let r = try await supplierLookup(q)
        let chosen: [SupplierProduct]
        if let spn, !spn.isEmpty {
            guard let hit = r.products.first(where: { $0.spn.caseInsensitiveCompare(spn) == .orderedSame && (supplier == nil || supplier == "" || $0.supplier == supplier) })
            else { throw Self.fail(404, "No listing \(spn) for \(q)" + (r.errors.isEmpty ? "." : " (\(r.errors.values.joined(separator: "; "))).")) }
            chosen = [hit]
        } else {
            chosen = InventoryCatalog.sameMPN(r.products, q)
            guard !chosen.isEmpty else { throw Self.fail(404, "Digi-Key and Mouser have nothing for \(q)" + (r.errors.isEmpty ? "." : " (\(r.errors.values.joined(separator: "; "))).")) }
        }
        // The part may have changed while the lookup was out (the actor took other requests): fill it as it is now.
        let i = try index(of: uid)
        for s in chosen { Self.fill(&b.parts[i], from: s) }
        try save()
        return (b.parts[i], chosen)
    }

    // MARK: Locations

    func updateLocation(_ id: String, _ f: [String: JSONValue]) throws -> Backup.Location {
        guard let i = b.locations.firstIndex(where: { $0.id == id }) else { throw Self.fail(404, "No location with id \(id).") }
        if let n = f["name"]?.string {
            guard !n.trimmed.isEmpty else { throw Self.fail(400, "A location needs a name.") }
            b.locations[i].name = n.trimmed
        }
        if let n = f["notes"] { b.locations[i].notes = n.string ?? "" }
        if let v = f["parentId"] {
            let parent = v.isNull || v.string == "" ? nil : v.string
            if let parent {
                guard b.locations.contains(where: { $0.id == parent }) else { throw Self.fail(400, "No location with id \(parent).") }
                // Not into itself or anything inside it.
                var seen = Set<String>(), at: String? = parent
                while let x = at, seen.insert(x).inserted {
                    if x == id { throw Self.fail(400, "A location can't go inside itself.") }
                    at = b.locations.first { $0.id == x }?.parentId
                }
            }
            b.locations[i].parentId = parent
        }
        b.locations[i].updated = Date.now.jsTime
        try save()
        return b.locations[i]
    }

    /// Remove a location; what was in it (parts and places) moves up to where it was.
    func deleteLocation(_ id: String) throws -> (name: String, moved: Int) {
        guard let i = b.locations.firstIndex(where: { $0.id == id }) else { throw Self.fail(404, "No location with id \(id).") }
        let l = b.locations[i], name = path(id)
        var moved = 0
        for j in b.parts.indices where b.parts[j].locationId == id { b.parts[j].locationId = l.parentId; b.parts[j].updated = Date.now.jsTime; moved += 1 }
        for j in b.locations.indices where b.locations[j].parentId == id { b.locations[j].parentId = l.parentId; b.locations[j].updated = Date.now.jsTime }
        b.locations.remove(at: i)
        for (k, ph) in photos.enumerated().reversed() where ph.locationId == id { store.deletePhoto(ph.id); photos.remove(at: k) }
        try save()
        return (name, moved)
    }
}
