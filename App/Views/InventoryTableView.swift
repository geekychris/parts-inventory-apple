import PartsKit
import SwiftData
import SwiftUI

/// Every part as a sortable table, narrowed by facets (category, maker, package, location, stock, tags, whose)
/// and the parametric search — this inventory's and friends'. On iPhone, a list with a filter sheet.
struct InventoryTableView: View {
    @Query private var parts: [Part]
    @AppStorage("defaultLowStock") private var defaultLow = 0
    @AppStorage("tableShowsFriends") private var showFriends = true
    @AppStorage("tableColumns") private var columnsJSON = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model = InventoryTableModel()
    @State private var selection: TableItem.ID?
    @State private var filtersShown = false
    @State private var friendsShown = false
    private let friends = FriendsStore.shared

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if sizeClass == .compact { compact } else { regular }
            }
            .navigationTitle("Table")
            .searchable(text: $model.search, prompt: "Search: lm358, 10k 0603 1%, cat:caps, low")
            .toolbar { toolbar }
        }
        .sheet(isPresented: $friendsShown) { FriendsSheet() }
        .onChange(of: parts.map(\.persistentModelID), initial: true) { model.setParts(parts, defaultLow: defaultLow) }
        .onChange(of: defaultLow) { model.setParts(parts, defaultLow: defaultLow) }
        .onChange(of: friends.version, initial: true) { model.friendsChanged(friends) }
        .onChange(of: showFriends, initial: true) { model.showFriends = showFriends }
        .task { await friends.refreshAll(olderThan: FriendsStore.refreshAge) }
        #if DEBUG
        .task { debugLaunch() }
        #endif
    }

    #if DEBUG
    /// `-tableFilter "category=Passives;source=Sam"`, `-tableSearch <q>`, `-tableSelect <part number>` (after a moment,
    /// once friends are loaded), `-tableFriends` (the friends sheet): for screenshots.
    func debugLaunch() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let q = value("-tableSearch") { model.search = q }
        for pair in (value("-tableFilter") ?? "").split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, let f = FacetKind(rawValue: kv[0]) { model.filter.toggle(f, kv[1] == "Mine" ? "" : kv[1]) }
        }
        if args.contains("-tableFriends") { friendsShown = true }
        if let mpn = value("-tableSelect") {
            Task { try? await Task.sleep(for: .seconds(2)); selection = model.shown.first { $0.row.mpn == mpn }?.id }
        }
    }
    #endif

    var selected: TableItem? { selection.flatMap { id in model.shown.first { $0.id == id } } }

    // MARK: Mac and iPad

    var regular: some View {
        HStack(spacing: 0) {
            FacetColumn(model: model, showsSource: showFriends && friends.hasFriends) { friendsShown = true }
                .frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                FilterChips(model: model)
                table
            }
        }
        .inspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selection = nil } })) {
            NavigationStack { detail }
                .inspectorColumnWidth(min: 340, ideal: 400, max: 560)
        }
    }

    var table: some View {
        @Bindable var model = model
        return Table(of: TableItem.self, selection: $selection, sortOrder: $model.sortOrder, columnCustomization: columns) {
            TableColumn("Part", value: \.row.title, comparator: .localizedStandard) { i in
                Text(i.row.title).help(i.row.title)
            }
            .width(min: 110, ideal: 150).customizationID("mpn").disabledCustomizationBehavior(.visibility)
            TableColumn("Manufacturer", value: \.row.manufacturer, comparator: .localizedStandard) { Text($0.row.manufacturer) }
                .width(min: 70, ideal: 110).customizationID("manufacturer")
            TableColumn("Description", value: \.row.description, comparator: .localizedStandard) { Text($0.row.description).help($0.row.description) }
                .width(min: 120, ideal: 220).customizationID("description")
            TableColumn("Category", value: \.row.category, comparator: .localizedStandard) { Text($0.row.categoryPath.joined(separator: " › ")) }
                .width(min: 70, ideal: 130).customizationID("category")
            TableColumn("Value", value: \.row.valueSort) { Text($0.row.valueText) }
                .width(min: 50, ideal: 90).customizationID("value")
            TableColumn("Package", value: \.row.package, comparator: .localizedStandard) { Text($0.row.package) }
                .width(min: 50, ideal: 70).customizationID("package")
            TableColumn("Qty", value: \.row.qty) { i in
                Text(i.row.qty, format: .number).monospacedDigit()
                    .foregroundStyle(i.row.qty == 0 ? .secondary : i.row.isLow ? Color.red : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 56).customizationID("qty")
            TableColumn("Location", value: \.row.location, comparator: .localizedStandard) { Text($0.row.location).help($0.row.location) }
                .width(min: 70, ideal: 140).customizationID("location")
            TableColumn("Updated", value: \.row.updated) { Text($0.row.updated, format: .dateTime.day().month(.abbreviated).year()) }
                .width(min: 70, ideal: 90).customizationID("updated")
            TableColumn("Source", value: \.row.source, comparator: .localizedStandard) { i in
                Text(i.isMine ? "Mine" : i.row.source).foregroundStyle(i.isMine ? .secondary : .primary)
            }
            .width(min: 50, ideal: 70).customizationID("source")
            .defaultVisibility(showFriends && friends.hasFriends ? .automatic : .hidden)
        } rows: {
            ForEach(model.shown) { TableRow($0) }
        }
        .overlay {
            if model.shown.isEmpty { empty }
        }
    }

    /// Column widths, order and hidden columns, remembered between launches.
    var columns: Binding<TableColumnCustomization<TableItem>> {
        Binding(get: { (try? JSONDecoder().decode(TableColumnCustomization<TableItem>.self, from: Data(columnsJSON.utf8))) ?? .init() },
                set: { columnsJSON = (try? JSONEncoder().encode($0)).map { String(decoding: $0, as: UTF8.self) } ?? "" })
    }

    @ViewBuilder var empty: some View {
        if model.total == 0 {
            ContentUnavailableView("No parts yet", systemImage: "tablecells",
                                   description: Text("Add parts in Parts, or a friend’s inventory from the Source filter."))
        } else {
            ContentUnavailableView.search
        }
    }

    @ViewBuilder var detail: some View {
        if let i = selected {
            if i.isMine, let p = model.part(i.row.id) {
                PartDetailView(part: p).id(p.id)
            } else if !i.isMine {
                FriendPartView(row: i.row).id(i.id)
            }
        }
    }

    // MARK: iPhone

    var compact: some View {
        List(model.shown) { i in
            NavigationLink(value: i.id) { CompactRow(item: i) }
        }
        .overlay { if model.shown.isEmpty { empty } }
        .safeAreaInset(edge: .top) { FilterChips(model: model) }
        .navigationDestination(for: TableItem.ID.self) { id in
            if let i = model.shown.first(where: { $0.id == id }) {
                if i.isMine, let p = model.part(i.row.id) { PartDetailView(part: p) } else { FriendPartView(row: i.row) }
            }
        }
        .sheet(isPresented: $filtersShown) {
            NavigationStack {
                FacetColumn(model: model, showsSource: showFriends && friends.hasFriends) { filtersShown = false; friendsShown = true }
                    .navigationTitle("Filter")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Clear all") { model.filter.clear() }.disabled(model.filter.isEmpty)
                        }
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { filtersShown = false } }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem {
            Text("\(model.shown.count) of \(model.total)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                .help("Parts shown, of all parts in the table")
        }
        if sizeClass == .compact {
            ToolbarItem {
                Button { filtersShown = true } label: {
                    Label("Filter", systemImage: model.filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        ToolbarItem {
            Menu {
                Toggle("Show friends’ parts", isOn: $showFriends)
                Button("Refresh friends’ inventories") { Task { await friends.refreshAll() } }.disabled(!friends.hasFriends)
                Button("Friends’ inventories…") { friendsShown = true }
            } label: { Label("Friends", systemImage: showFriends && friends.hasFriends ? "person.2.fill" : "person.2") }
                .help("Friends’ inventories")
        }
        // ExportMenu(rows: model.shown.map(\.row)) goes here once feat/exports is merged
    }
}

/// A row of the iPhone list.
private struct CompactRow: View {
    let item: TableItem
    var body: some View {
        let r = item.row
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.headline).lineLimit(1)
                Text([r.valueText, r.description].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                let whereText = [item.isMine ? "" : r.source, r.location].filter { !$0.isEmpty }.joined(separator: " · ")
                if !whereText.isEmpty {
                    Label(whereText, systemImage: item.isMine ? "archivebox" : "person.2").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text("\(r.qty)").monospacedDigit().foregroundStyle(r.qty == 0 ? .secondary : r.isLow ? Color.red : .primary)
        }
    }
}
