import CoreGraphics
import Foundation
import Observation
import PartsKit
import SwiftData

/// Adding many parts quickly: each photo is read and identified, looked up at Digi-Key and Mouser, and waits
/// for a yes — or is added straight away when the number read on the part matches one listing exactly.
@Observable
final class BatchModel {
    enum Status: Equatable {
        case waiting, reading, lookingUp, ready, needsNumber, added, skipped
        case failed(String)

        var title: String {
            switch self {
            case .waiting: "Waiting"
            case .reading: "Reading"
            case .lookingUp: "Looking up"
            case .ready: "Ready"
            case .needsNumber: "Needs a number"
            case .added: "Added"
            case .skipped: "Skipped"
            case .failed: "Failed"
            }
        }
        var isDone: Bool { self == .added || self == .skipped }
        var isBusy: Bool { self == .waiting || self == .reading || self == .lookingUp }
    }

    @Observable
    final class Item: Identifiable {
        let id = UUID()
        let photo: Data
        let thumb: CGImage?
        let image: CGImage?
        var status: Status = .waiting
        /// The markings as read.
        var markings = ""
        var label: BagLabel?
        var candidates: [Candidate] = []
        /// The part number looked up (editable: "Search again" uses it).
        var query = ""
        var results: [SupplierProduct] = []
        var errors: [String: String] = [:]
        var chosen: SupplierProduct.ID?
        var sure = false
        var qty: Int
        /// The part it went to, once added.
        var partID: String?
        var note = ""

        init(photo: Data, qty: Int) {
            self.photo = photo
            self.qty = qty
            image = Images.cgImage(photo, maxSide: 2048)
            thumb = Images.cgImage(photo, maxSide: 240)
        }

        var choice: SupplierProduct? { results.first { $0.id == chosen } ?? results.first }
        /// The other supplier's listing of the chosen part, added alongside it.
        var partner: SupplierProduct? { choice.flatMap { BatchMatch.partner(of: $0, in: results) } }
        /// Without supplier listings, the best catalog or inventory candidate.
        var fallback: Candidate? { candidates.first { if case .generic = $0.source { false } else { $0.score >= 0.4 } } }
        var title: String {
            if let c = choice { return c.mpn }
            if let l = label, l.hasPart { return l.mpn.isEmpty ? l.spn : l.mpn }
            if let c = fallback { return CandidateCard.searchable(c) ?? "Part" }
            return query.isEmpty ? "Photo" : query
        }
    }

    var items: [Item] = []
    var selection: Item.ID?
    var defaultQty = 1
    var autoAdd = false
    /// Called when an item is sure and auto-add is on; the view adds it (it has the model context).
    @ObservationIgnored var onSure: ((Item) -> Void)?

    private var running = 0
    private let maxRunning = 2
    @ObservationIgnored private let limiter = RateLimiter(perMinute: 9)

    var counts: (queued: Int, ready: Int, added: Int, skipped: Int) {
        (items.filter { $0.status.isBusy }.count, items.filter { $0.status == .ready || $0.status == .needsNumber || $0.status.isFailed }.count,
         items.filter { $0.status == .added }.count, items.filter { $0.status == .skipped }.count)
    }
    var selected: Item? { items.first { $0.id == selection } }

    // MARK: Queue

    func enqueue(_ data: Data, inventory: @escaping () -> [InventoryRef], lookWhen: IdentifyModel.LookWhen, useAI: Bool) {
        guard let jpeg = Images.jpeg(data, maxSide: 2048) else { return }
        let item = Item(photo: jpeg, qty: defaultQty)
        guard item.image != nil else { return }
        items.append(item)
        if selection == nil || selected?.status.isDone == true { selection = item.id }
        pump(inventory: inventory, lookWhen: lookWhen, useAI: useAI)
    }

    private func pump(inventory: @escaping () -> [InventoryRef], lookWhen: IdentifyModel.LookWhen, useAI: Bool) {
        while running < maxRunning, let next = items.first(where: { $0.status == .waiting }) {
            running += 1
            next.status = .reading
            Task {
                await process(next, inventory: inventory(), lookWhen: lookWhen, useAI: useAI)
                running -= 1
                pump(inventory: inventory, lookWhen: lookWhen, useAI: useAI)
            }
        }
    }

    /// Read and identify the photo (as Identify does), then look up the best numbers.
    private func process(_ item: Item, inventory: [InventoryRef], lookWhen: IdentifyModel.LookWhen, useAI: Bool) async {
        let m = IdentifyModel()
        m.set(item.photo)
        if let e = m.error { item.status = .failed(e); return }
        await m.identify(inventory: inventory, lookWhen: lookWhen, useAI: useAI)
        item.markings = m.markings
        item.label = m.label
        item.candidates = m.candidates
        if let q = m.label?.qty, q > 0 { item.qty = q }
        let queries = BatchMatch.queries(label: item.label, candidates: item.candidates)
        item.query = queries.first ?? ""
        await lookUp(item, queries: queries)
    }

    /// Look up `queries` in order, stopping at the first that finds a listing whose number was read or asked for.
    func lookUp(_ item: Item, queries: [String]) async {
        let keys = SupplierKeys.shared
        guard !queries.isEmpty else {
            item.status = item.fallback != nil || item.label?.hasPart == true ? .ready : .needsNumber
            return
        }
        guard keys.isConfigured else {
            item.status = item.fallback != nil || item.label?.hasPart == true ? .ready : .needsNumber
            return
        }
        item.status = .lookingUp
        var all: [SupplierProduct] = []
        var errors: [String: String] = [:]
        for q in queries {
            await limiter.wait()
            let r = await keys.lookup.lookup(q)
            errors.merge(r.errors) { a, _ in a }
            all += r.products.filter { p in !all.contains { $0.id == p.id } }
            let ranked = BatchMatch.rank(all, ocrText: item.markings, label: item.label, queries: queries)
            if let best = ranked.first, BatchMatch.tier(best, read: BatchMatch.readKeys(item.markings), label: item.label, queries: queries) <= 1 { break }
        }
        item.results = BatchMatch.rank(all, ocrText: item.markings, label: item.label, queries: queries)
        item.errors = errors
        item.chosen = item.results.first?.id
        item.sure = BatchMatch.isSure(item.results, ocrText: item.markings, label: item.label, queries: queries)
        item.status = item.results.isEmpty && item.fallback == nil && item.label?.hasPart != true ? .needsNumber : .ready
        if item.sure && autoAdd && item.status == .ready { onSure?(item) }
    }

    /// Look up the part number typed in by hand.
    func searchAgain(_ item: Item) {
        let q = item.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        item.results = []; item.chosen = nil; item.sure = false
        Task { await lookUp(item, queries: [q]) }
    }

    // MARK: Review

    func skip(_ item: Item) {
        item.status = .skipped
        selectNext(after: item)
    }

    /// The next item waiting for a decision (or still being read), after `item` and then from the start.
    func selectNext(after item: Item? = nil) {
        let open = { (i: Item) in !i.status.isDone }
        let start = item.flatMap { it in items.firstIndex { $0.id == it.id } } ?? -1
        let later = items.dropFirst(start + 1).first(where: open), earlier = items.prefix(max(start, 0)).first(where: open)
        if let n = later ?? earlier { selection = n.id }
    }

    func move(_ by: Int) {
        guard !items.isEmpty else { return }
        let i = items.firstIndex { $0.id == selection } ?? 0
        selection = items[min(max(i + by, 0), items.count - 1)].id
    }

    func clearDone() {
        items.removeAll { $0.status.isDone }
        if selected == nil { selectNext() }
    }

    // MARK: Adding

    /// The part this item would add stock to, if it's already in the inventory.
    @MainActor
    static func existing(_ item: Item, in ctx: ModelContext) -> Part? {
        if let p = item.choice { return Inventory.find(spn: p.spn, supplier: p.supplier, mpn: p.mpn, manufacturer: p.manufacturer, in: ctx) }
        if let l = item.label, l.hasPart { return Inventory.find(spn: l.spn, supplier: l.supplier, mpn: l.mpn, manufacturer: l.manufacturer, in: ctx) }
        if let c = item.fallback, case .inventory(let ref) = c.source { return Inventory.allParts(ctx).first { $0.uid == ref.id } }
        return nil
    }

    /// Add the item: stock on the part it matches, or a new part with everything the listings give —
    /// both suppliers' numbers and prices, the datasheet, package, parameters and the photo.
    @MainActor @discardableResult
    func add(_ item: Item, location: StorageLocation?, in ctx: ModelContext) -> Part? {
        guard item.status == .ready || item.status == .needsNumber else { return nil }
        var added: Part?
        let qty = max(item.qty, 0)
        let date = Date.now.formatted(date: .abbreviated, time: .omitted)
        if let part = Self.existing(item, in: ctx) {
            if let p = item.choice { Inventory.fill(part, from: p) }
            if let o = item.partner { Inventory.fill(part, from: o) }
            if qty > 0 { Inventory.adjust(part, by: qty, reason: "Batch add", in: ctx, supplier: item.label?.supplier, lot: item.label.flatMap { $0.lot.isEmpty ? nil : $0.lot }) }
            if part.location == nil { part.location = location }
            item.partID = part.uid
            item.note = "Added \(qty) to \(part.title)"
            added = part
        } else if let p = item.choice {
            var d = PartDraft()
            d.fill(from: p)
            if let o = item.partner { d.fill(from: o) }
            d.qty = qty
            d.tags = ["batch"]
            d.notes = "Added in a batch on \(date)." + (item.markings.isEmpty ? "" : "\nMarkings read: " + item.markings.replacingOccurrences(of: "\n", with: " ").prefix(300))
            let part = Inventory.add(d, photo: item.photo, location: location, in: ctx)
            if part.imageURL.isEmpty { part.imageURL = p.image }
            item.partID = part.uid
            item.note = "New part"
            added = part
        } else if let l = item.label, l.hasPart, let r = Inventory.receive(l, qty: qty, location: location, in: ctx) {
            item.partID = r.part.uid
            item.note = r.isNew ? "New part" : "Added \(qty) to \(r.part.title)"
            added = r.part
        } else if let c = item.fallback {
            var d = Identify.draft(c, ocrText: item.markings)
            d.qty = qty
            d.tags.append("batch")
            let part = Inventory.add(d, photo: item.photo, location: location, in: ctx)
            item.partID = part.uid
            item.note = "New part"
            added = part
        } else {
            return nil
        }
        item.status = .added
        selectNext(after: item)
        return added
    }

    /// Nothing left to check or still being read.
    var isClear: Bool { items.allSatisfy { $0.status.isDone } }
}

extension BatchModel.Status {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

/// At most `perMinute` calls a minute, spaced evenly (Mouser allows 30 calls a minute, and one lookup can
/// make up to three).
actor RateLimiter {
    private let gap: Duration
    private var next = ContinuousClock.now

    init(perMinute: Int) { gap = .milliseconds(60_000 / max(perMinute, 1)) }

    func wait() async {
        let now = ContinuousClock.now
        let at = max(next, now)
        next = at + gap
        if at > now { try? await Task.sleep(until: at) }
    }
}
