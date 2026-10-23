import PartsKit
import SwiftData
import SwiftUI

/// Where things are kept: a tree of cabinets, shelves, drawers and bins, and what's in each. Parts and
/// locations are dragged onto a location to move them there (or moved with Move To in their menus).
struct LocationsView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(AppModel.self) private var app
    @Query(sort: \StorageLocation.name) private var all: [StorageLocation]
    @Query private var parts: [Part]
    @State private var selection: LocationSelection?
    @State private var newPath = ""
    @State private var renaming: StorageLocation?
    @State private var newName = ""
    @State private var adding: NewLocationRequest?

    var roots: [StorageLocation] { all.filter { $0.parent == nil }.sorted(by: StorageLocation.siblingOrder) }
    var unstored: [Part] { parts.filter { $0.location == nil } }
    var selected: StorageLocation? {
        guard case .location(let id) = selection else { return nil }
        return all.first { $0.id == id }
    }

    var body: some View {
        MasterDetail {
            List(selection: $selection) {
                Section {
                    HStack {
                        TextField("New: Cabinet A / Shelf 2 / Drawer 3", text: $newPath).onSubmit(add)
                        Button("Add", action: add).disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    DropRow(target: nil, mover: mover) {
                        HStack {
                            Label("Not stored anywhere", systemImage: "questionmark.folder")
                            Spacer()
                            Text("\(unstored.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .tag(LocationSelection.unstored)
                }
                Section("Locations") {
                    OutlineGroup(roots, children: \.sortedChildren) { l in
                        DropRow(target: l, mover: mover) {
                            HStack {
                                Label(l.name, systemImage: l.resolvedKind.symbol)
                                Spacer()
                                Text("\(l.partCount)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .draggable(LocationDrag.locations([l.uid]))
                        .tag(LocationSelection.location(l.id))
                        .contextMenu { menu(for: l) }
                    }
                }
            }
            .navigationTitle("Locations")
            .toolbar { ToolbarItem { addMenu } }
            .overlay { if all.isEmpty { ContentUnavailableView("No locations yet", systemImage: "cabinet", description: Text("Add a cabinet with the + button, or type “Cabinet A / Shelf 2” to make both at once.")) } }
        } detail: {
            switch selection {
            case .unstored:
                PartsHere(title: "Not stored anywhere", parts: unstored, here: nil, mover: mover, locations: all)
            case .location:
                if let l = selected {
                    LocationDetail(location: l, mover: mover, locations: all, onAdd: { adding = .init(kind: $0, parent: l) })
                } else {
                    ContentUnavailableView("Choose a location", systemImage: "cabinet")
                }
            case nil:
                ContentUnavailableView("Choose a location", systemImage: "cabinet",
                                       description: Text("Drag parts onto a cabinet, shelf or drawer to move them there; drag a shelf onto another cabinet to move it with everything in it."))
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { renaming?.name = newName; renaming?.updated = .now; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .sheet(item: $adding) { req in
            NewLocationSheet(request: req, locations: all) { made in
                if let first = made.first { selection = .location(first.id) }
            }
        }
    }

    var mover: LocationMover { LocationMover(ctx: ctx, locations: all, parts: parts) }

    var addMenu: some View {
        Menu {
            if let l = selected {
                Section("Inside \(l.name)") {
                    ForEach(kindsFirst(l.resolvedKind.usualChild)) { k in
                        Button("New \(k.label)…", systemImage: k.symbol) { adding = .init(kind: k, parent: l) }
                    }
                }
            }
            Section("At the top level") {
                ForEach([LocationKind.cabinet, .shelf, .box, .other]) { k in
                    Button("New \(k.label)…", systemImage: k.symbol) { adding = .init(kind: k, parent: nil) }
                }
            }
        } label: {
            Label("Add Location", systemImage: "plus")
        }
        .help("Add a cabinet, shelf, drawer, bin or box")
    }

    @ViewBuilder func menu(for l: StorageLocation) -> some View {
        Menu("Add Inside", systemImage: "plus") {
            ForEach(kindsFirst(l.resolvedKind.usualChild)) { k in
                Button("New \(k.label)…", systemImage: k.symbol) { adding = .init(kind: k, parent: l) }
            }
        }
        Button("Rename…") { renaming = l; newName = l.name }
        Picker("Kind", selection: Binding(get: { l.resolvedKind }, set: { l.kind = $0.rawValue; l.updated = .now })) {
            ForEach(LocationKind.allCases) { k in Label(k.label, systemImage: k.symbol).tag(k) }
        }
        MoveToMenu(locations: all, excluding: l, topLevelTitle: "Top Level") { target in
            mover.move(.locations([l.uid]), to: target)
        }
        Divider()
        Button("Delete", role: .destructive) { delete(l) }
    }

    func kindsFirst(_ k: LocationKind) -> [LocationKind] { [k] + LocationKind.allCases.filter { $0 != k } }

    func add() {
        if let l = Inventory.ensureLocation(newPath, in: ctx) { selection = .location(l.id) }
        newPath = ""
    }

    /// Children move up to the parent; parts stored here lose their location.
    func delete(_ l: StorageLocation) {
        for c in l.children ?? [] { c.parent = l.parent }
        for p in l.parts ?? [] { p.location = nil }
        if selected == l { selection = nil }
        ctx.delete(l)
    }
}

enum LocationSelection: Hashable {
    case unstored
    case location(PersistentIdentifier)
}

/// What's being dragged: some parts or some locations, by uid.
enum LocationDrag: Transferable {
    case parts([String])
    case locations([String])

    struct NotOurs: Error {}

    /// Carried as text ("parts:p1,p2"), which only this app's lists accept back.
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.text, importing: { (s: String) throws -> LocationDrag in
            guard let d = LocationDrag(text: s) else { throw NotOurs() }
            return d
        })
    }

    var text: String {
        switch self {
        case .parts(let ids): "parts:" + ids.joined(separator: ",")
        case .locations(let ids): "locations:" + ids.joined(separator: ",")
        }
    }

    init?(text: String) {
        let (kind, rest) = (text.prefix { $0 != ":" }, text.drop { $0 != ":" }.dropFirst())
        let ids = rest.split(separator: ",").map(String.init)
        guard !ids.isEmpty else { return nil }
        switch kind {
        case "parts": self = .parts(ids)
        case "locations": self = .locations(ids)
        default: return nil
        }
    }
}

/// Moves parts and locations, refusing to put a location inside itself.
struct LocationMover {
    let ctx: ModelContext
    let locations: [StorageLocation]
    let parts: [Part]

    /// Can `drag` go into `target` (nil: not stored / the top level)?
    func canMove(_ drag: LocationDrag, to target: StorageLocation?) -> Bool {
        switch drag {
        case .parts(let ids):
            return parts.contains { ids.contains($0.uid) && $0.location?.uid != target?.uid }
        case .locations(let ids):
            let moving = locations.filter { ids.contains($0.uid) }
            guard !moving.isEmpty else { return false }
            if let target { return moving.allSatisfy { !$0.contains(target) && $0.parent?.uid != target.uid } }
            return moving.contains { $0.parent != nil }
        }
    }

    @discardableResult
    func move(_ drag: LocationDrag, to target: StorageLocation?) -> Bool {
        guard canMove(drag, to: target) else { return false }
        switch drag {
        case .parts(let ids):
            for p in parts where ids.contains(p.uid) { p.location = target; p.updated = .now }
        case .locations(let ids):
            let siblings = target?.children ?? locations.filter { $0.parent == nil }
            var order = (siblings.map(\.order).max() ?? 0) + 1
            for l in locations where ids.contains(l.uid) {
                l.parent = target; l.order = order; l.updated = .now
                order += 1
            }
        }
        try? ctx.save()
        return true
    }
}

/// A row that takes dropped parts and locations, and lights up while something can be dropped on it.
struct DropRow<Content: View>: View {
    let target: StorageLocation?
    let mover: LocationMover
    @ViewBuilder var content: Content
    @State private var targeted = false

    var body: some View {
        content
            .padding(.vertical, 2)
            .background(targeted ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 5))
            .contentShape(.rect)
            .dropDestination(for: LocationDrag.self) { items, _ in
                items.reduce(false) { mover.move($1, to: target) || $0 }
            } isTargeted: { targeted = $0 }
    }
}

/// A Move To menu listing every location (except `excluding` and what's inside it).
struct MoveToMenu: View {
    let locations: [StorageLocation]
    var excluding: StorageLocation?
    var topLevelTitle = "Not Stored Anywhere"
    let action: (StorageLocation?) -> Void

    var body: some View {
        Menu("Move To", systemImage: "arrow.right.square") {
            Button(topLevelTitle) { action(nil) }
            Divider()
            ForEach(targets) { l in
                Button(l.path, systemImage: l.resolvedKind.symbol) { action(l) }
            }
        }
    }

    var targets: [StorageLocation] {
        locations.filter { l in excluding.map { !$0.contains(l) } ?? true }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// One location: what it is, the locations inside it and the parts stored in it.
struct LocationDetail: View {
    @Bindable var location: StorageLocation
    let mover: LocationMover
    let locations: [StorageLocation]
    let onAdd: (LocationKind) -> Void
    @AppStorage("locationsIncludeInside") private var includeInside = false

    var body: some View {
        let inside = location.sortedChildren ?? []
        let shown = includeInside ? location.allParts : (location.parts ?? [])
        PartsHere(title: location.path, parts: shown, here: location, mover: mover, locations: locations) {
            Section {
                Picker("Kind", selection: Binding(get: { location.resolvedKind }, set: { location.kind = $0.rawValue; location.updated = .now })) {
                    ForEach(LocationKind.allCases) { k in Label(k.label, systemImage: k.symbol).tag(k) }
                }
                TextField("Notes", text: $location.notes, axis: .vertical)
            }
            Section {
                ForEach(inside) { c in
                    DropRow(target: c, mover: mover) {
                        HStack {
                            Label(c.name, systemImage: c.resolvedKind.symbol)
                            Spacer()
                            Text("\(c.partCount)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .draggable(LocationDrag.locations([c.uid]))
                }
                Button("Add \(location.resolvedKind.usualChild.label) Inside…", systemImage: "plus") { onAdd(location.resolvedKind.usualChild) }
            } header: {
                Text(inside.isEmpty ? "Nothing inside" : "Inside (\(inside.count))")
            }
        } footer: {
            if !inside.isEmpty { Toggle("Include parts in the locations inside", isOn: $includeInside) }
        }
    }
}

/// A list of parts that can be dragged out (several at once when selected) and opened with a double-click.
struct PartsHere<Header: View, Footer: View>: View {
    @Environment(AppModel.self) private var app
    let title: String
    let parts: [Part]
    let here: StorageLocation?
    let mover: LocationMover
    let locations: [StorageLocation]
    @ViewBuilder var header: Header
    @ViewBuilder var footer: Footer
    @State private var picked = Set<PersistentIdentifier>()

    init(title: String, parts: [Part], here: StorageLocation?, mover: LocationMover, locations: [StorageLocation],
         @ViewBuilder header: () -> Header = { EmptyView() }, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.title = title; self.parts = parts; self.here = here; self.mover = mover; self.locations = locations
        self.header = header(); self.footer = footer()
    }

    var body: some View {
        let sorted = parts.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        List(selection: $picked) {
            header
            Section {
                if sorted.isEmpty {
                    Text(here == nil ? "Every part has a place." : "Nothing stored here. Drag parts onto it from another location.").foregroundStyle(.secondary)
                }
                ForEach(sorted) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        PartRow(part: p)
                        if let l = p.location, let here, l.uid != here.uid {
                            Text("in " + l.path).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 52)
                        }
                    }
                    .draggable(LocationDrag.parts(dragIDs(p))) {
                        Label(dragIDs(p).count == 1 ? p.title : "\(dragIDs(p).count) parts", systemImage: "shippingbox")
                            .padding(6).background(.regularMaterial, in: .rect(cornerRadius: 6))
                    }
                }
            } header: {
                Text("Parts (\(sorted.count))")
            } footer: {
                footer
            }
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if !ids.isEmpty {
                MoveToMenu(locations: locations) { target in
                    mover.move(.parts(uids(ids)), to: target)
                    picked = []
                }
                if ids.count == 1, let p = parts.first(where: { ids.contains($0.id) }) {
                    Button("Show Part") { open(p) }
                }
            }
        } primaryAction: { ids in
            if let p = parts.first(where: { ids.contains($0.id) }) { open(p) }
        }
        .navigationTitle(title)
    }

    /// Dragging a selected part takes the whole selection; any other part goes alone.
    func dragIDs(_ p: Part) -> [String] {
        picked.contains(p.id) ? uids(picked) : [p.uid]
    }

    func uids(_ ids: Set<PersistentIdentifier>) -> [String] { parts.filter { ids.contains($0.id) }.map(\.uid) }

    func open(_ p: Part) { app.partToShow = p.uid; app.tab = .parts }
}

struct NewLocationRequest: Identifiable {
    let id = UUID()
    var kind: LocationKind
    var parent: StorageLocation?
}

/// Make one location, or a run of them ("Drawer 1" × 6 makes Drawer 1 to Drawer 6).
struct NewLocationSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    let request: NewLocationRequest
    let locations: [StorageLocation]
    let onMade: ([StorageLocation]) -> Void
    @State private var name = ""
    @State private var kind = LocationKind.cabinet
    @State private var parentID: String?
    @State private var count = 1

    var parent: StorageLocation? { parentID.flatMap { id in locations.first { $0.uid == id } } }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    ForEach(LocationKind.allCases) { k in Label(k.label, systemImage: k.symbol).tag(k) }
                }
                Picker("Inside", selection: $parentID) {
                    Text("Top level").tag(String?.none)
                    ForEach(locations.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) { l in
                        Text(l.path).tag(Optional(l.uid))
                    }
                }
                Stepper(count == 1 ? "Make one" : "Make \(count): \(names.first ?? "") to \(names.last ?? "")", value: $count, in: 1...50)
            }
            .formStyle(.grouped)
            .navigationTitle("New \(kind.label)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { make(); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 280)
        .onAppear {
            kind = request.kind
            parentID = request.parent?.uid
            name = suggestedName
        }
        .onChange(of: kind) { old, _ in if name == suggested(old) { name = suggestedName } }
        .onChange(of: parentID) { if LocationKind.allCases.contains(where: { name == suggested($0) }) { name = suggestedName } }
    }

    var siblings: [StorageLocation] { parent?.children ?? locations.filter { $0.parent == nil } }
    var suggestedName: String { suggested(kind) }
    func suggested(_ k: LocationKind) -> String { k.nextName(among: siblings.map(\.name)) }

    /// The names to make: "Drawer 3" with a count of 3 is Drawer 3, Drawer 4 and Drawer 5.
    var names: [String] {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard count > 1 else { return [n] }
        let digits = n.reversed().prefix { $0.isNumber }
        let start = Int(String(digits.reversed())) ?? 1
        let stem = digits.isEmpty ? n + " " : String(n.dropLast(digits.count))
        return (0..<count).map { "\(stem)\(start + $0)" }
    }

    func make() {
        var order = (siblings.map(\.order).max() ?? 0) + 1
        var made: [StorageLocation] = []
        for n in names where !n.isEmpty {
            let l = StorageLocation(name: n, parent: parent)
            l.kind = kind.rawValue; l.order = order
            ctx.insert(l); made.append(l)
            order += 1
        }
        try? ctx.save()
        onMade(made)
    }
}

extension StorageLocation {
    /// Their own order first, then by name with numbers in number order (Drawer 2 before Drawer 10).
    static func siblingOrder(_ a: StorageLocation, _ b: StorageLocation) -> Bool {
        a.order != b.order ? a.order < b.order : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
