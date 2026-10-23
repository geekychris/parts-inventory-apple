import Foundation
import PartsKit

/// A row in the table: an `InventoryRow` with an id that's unique across this inventory and friends' (a
/// friend's backup can carry the same part ids as this one).
nonisolated struct TableItem: Identifiable, Hashable, Sendable {
    let id: String
    let row: InventoryRow
    var isMine: Bool { row.source.isEmpty }
}

nonisolated extension InventoryRow {
    /// For sorting the Value column: by kind, then the number.
    var valueSort: Double { params.value ?? -1 }
}

extension Part {
    /// This part as a table row (as `Backup.rows` would make it, without making a whole backup).
    func row(defaultLow: Int) -> InventoryRow {
        let path = location.map { l -> [String] in
            var names: [String] = [], seen = Set<String>(), cur: StorageLocation? = l
            while let x = cur, seen.insert(x.uid).inserted { names.insert(x.name, at: 0); cur = x.parent }
            return names
        } ?? []
        let lim = lowStock ?? defaultLow
        var x = Backup.Part(id: uid)
        x.mpn = mpn; x.manufacturer = manufacturer; x.description = partDescription; x.category = category; x.package = package
        x.params = params; x.qty = Double(qty); x.suppliers = suppliers; x.datasheet = datasheet; x.notes = notes; x.tags = tags
        x.updated = updated.jsTime
        return InventoryRow(x, locationPath: path, lowStock: lim > 0 ? lim : nil)
    }
}

/// The table's data: this inventory's parts (kept live) and friends' parts, the search and facet choices, and
/// the rows and facet counts they give — worked out once per change, not on every redraw.
@Observable
final class InventoryTableModel {
    var search = "" { didSet { if search != oldValue { recompute() } } }
    var filter = FacetFilter() { didSet { if filter != oldValue { recompute() } } }
    var sortOrder = [KeyPathComparator(\TableItem.row.title, comparator: .localizedStandard)] { didSet { sortShown() } }
    var showFriends = true { didSet { if showFriends != oldValue { reindex() } } }

    private(set) var shown: [TableItem] = []
    private(set) var facets: [FacetKind: [FacetNode]] = [:]
    private(set) var total = 0

    @ObservationIgnored private var parts: [Part] = []
    @ObservationIgnored private var byUID: [String: Part] = [:]
    @ObservationIgnored private var defaultLow = 0
    @ObservationIgnored private var mine: [InventoryRow] = []
    @ObservationIgnored private var items: [TableItem] = []
    @ObservationIgnored private var index = FacetIndex([])
    @ObservationIgnored private var matched: [TableItem] = []
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var friendsVersion = -1

    func part(_ uid: String) -> Part? { byUID[uid] }

    /// The parts list changed (added or deleted), or the default low-stock level.
    func setParts(_ parts: [Part], defaultLow: Int) {
        self.parts = parts; self.defaultLow = defaultLow
        byUID = Dictionary(parts.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        rebuildMine()
    }

    /// Friends' rows changed (fetched, renamed, removed).
    func friendsChanged(_ store: FriendsStore) {
        guard store.version != friendsVersion else { return }
        friendsVersion = store.version
        reindex()
    }

    /// Map the parts to rows, watching every property read: an edit anywhere (stock, a field, a location's name)
    /// rebuilds them, a moment later so typing in a part's page doesn't rebuild on every key.
    private func rebuildMine() {
        pending?.cancel(); pending = nil
        mine = withObservationTracking {
            parts.map { $0.row(defaultLow: defaultLow) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRebuild() }
        }
        reindex()
    }

    private func scheduleRebuild() {
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            // A part deleted meanwhile is no longer valid to read.
            self.parts.removeAll { $0.isDeleted || $0.modelContext == nil }
            self.rebuildMine()
        }
    }

    private func reindex() {
        let friends = showFriends ? FriendsStore.shared.allRows : []
        items = mine.map { TableItem(id: $0.id, row: $0) } + friends.map { TableItem(id: $0.source + "\u{1F}" + $0.id, row: $0) }
        index = FacetIndex(items.map(\.row))
        total = items.count
        recompute()
    }

    private func recompute() {
        let r = index.result(PartQuery(search), filter)
        facets = r.facets
        matched = r.matches.map { items[$0] }
        sortShown()
    }

    private func sortShown() { shown = matched.sorted(using: sortOrder) }
}
