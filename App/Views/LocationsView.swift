import SwiftData
import SwiftUI

/// Where things are kept: a tree of cabinets, drawers and bins, and what's in each.
struct LocationsView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(AppModel.self) private var app
    @Query(sort: \StorageLocation.name) private var all: [StorageLocation]
    @State private var selection: StorageLocation.ID?
    @State private var newPath = ""
    @State private var renaming: StorageLocation?
    @State private var newName = ""

    var roots: [StorageLocation] { all.filter { $0.parent == nil }.sorted { ($0.order, $0.name) < ($1.order, $1.name) } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    HStack {
                        TextField("New: Cabinet A / Drawer 3", text: $newPath).onSubmit(add)
                        Button("Add", action: add).disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                OutlineGroup(roots, children: \.sortedChildren) { l in
                    HStack {
                        Label(l.name, systemImage: l.children?.isEmpty == false ? "archivebox" : "tray")
                        Spacer()
                        Text("\(l.partCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(l.id)
                    .contextMenu {
                        Button("Rename…") { renaming = l; newName = l.name }
                        Button("Add inside…") { newPath = l.path.replacingOccurrences(of: " › ", with: " / ") + " / " }
                        Button("Delete", role: .destructive) { delete(l) }
                    }
                }
            }
            .navigationTitle("Locations")
            .overlay { if all.isEmpty { ContentUnavailableView("No locations yet", systemImage: "archivebox", description: Text("Add “Cabinet A / Drawer 3” to make both at once.")) } }
        } detail: {
            if let id = selection, let l = all.first(where: { $0.id == id }) {
                List {
                    let parts = (l.parts ?? []).sorted { $0.title < $1.title }
                    if parts.isEmpty { Text("Nothing stored here directly.").foregroundStyle(.secondary) }
                    ForEach(parts) { p in
                        Button { app.partToShow = p.uid; app.tab = .parts } label: { PartRow(part: p) }.buttonStyle(.plain)
                    }
                }
                .navigationTitle(l.path)
            } else {
                ContentUnavailableView("Choose a location", systemImage: "archivebox")
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { renaming?.name = newName; renaming?.updated = .now; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    func add() {
        if let l = Inventory.ensureLocation(newPath, in: ctx) { selection = l.id }
        newPath = ""
    }

    /// Children move up to the parent; parts stored here lose their location.
    func delete(_ l: StorageLocation) {
        for c in l.children ?? [] { c.parent = l.parent }
        for p in l.parts ?? [] { p.location = nil }
        ctx.delete(l)
    }
}
