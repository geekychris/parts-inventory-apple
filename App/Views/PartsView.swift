import PartsKit
import SwiftData
import SwiftUI

/// The inventory: a searchable list (with the parametric search "10k 0603 1%") and a part's page.
struct PartsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Part.mpn) private var parts: [Part]
    @State private var search = ""
    @State private var selection: Part.ID?
    /// Always open with the list showing: a restored split can come back with it collapsed to nothing.
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var category = ""
    @AppStorage("defaultLowStock") private var defaultLow = 0

    var filtered: [Part] {
        let q = PartQuery(search)
        return parts.filter { (category.isEmpty || $0.category.hasPrefix(category)) && (q.isEmpty || $0.matches(q, defaultLow: defaultLow)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var categories: [String] {
        Array(Set(parts.compactMap { $0.category.split(separator: "/").first.map(String.init) })).sorted()
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                if parts.isEmpty {
                    ContentUnavailableView {
                        Label("No parts yet", systemImage: "shippingbox")
                    } description: {
                        Text("Scan a bag label, identify a part from a photo, add one by hand, or import a backup from the web version in Settings.")
                    }
                }
                ForEach(filtered) { p in
                    PartRow(part: p, low: p.isLow(defaultLimit: defaultLow)).tag(p.id)
                }
                .onDelete { idx in
                    for i in idx { ctx.delete(filtered[i]) }
                }
            }
            .navigationTitle("Parts")
            .searchable(text: $search, prompt: "Search: lm358, 10k 0603 1%, cat:caps, low")
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker("Category", selection: $category) {
                            Text("All categories").tag("")
                            ForEach(categories, id: \.self) { Text($0).tag($0) }
                        }
                    } label: { Label("Category", systemImage: category.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                }
                ToolbarItem {
                    Button { addPart() } label: { Label("Add part", systemImage: "plus") }
                        .keyboardShortcut("n")
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            if let id = selection, let p = parts.first(where: { $0.id == id }) {
                PartDetailView(part: p).id(p.id)
            } else {
                ContentUnavailableView("Choose a part", systemImage: "shippingbox", description: Text("\(parts.count) parts, \(parts.reduce(0) { $0 + $1.qty }) units."))
            }
        }
        .onChange(of: app.partToShow, initial: true) { _, uid in
            guard let uid, let p = parts.first(where: { $0.uid == uid }) else { return }
            selection = p.id
            app.partToShow = nil
        }
    }

    func addPart() {
        let p = Part()
        p.mpn = ""
        ctx.insert(p)
        selection = p.id
    }
}

struct PartRow: View {
    let part: Part
    var low = false

    var body: some View {
        HStack(spacing: 12) {
            if let ph = part.sortedPhotos.first?.data, let img = Image(data: ph) {
                img.resizable().scaledToFill().frame(width: 40, height: 40).clipShape(.rect(cornerRadius: 6))
            } else {
                Image(systemName: icon).font(.title3).frame(width: 40, height: 40).background(.quaternary, in: .rect(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(part.title).font(.headline).lineLimit(1)
                Text([part.paramsSummary, part.partDescription].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let loc = part.location { Label(loc.path, systemImage: "archivebox").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text("\(part.qty)").font(.body.monospacedDigit()).foregroundStyle(low ? .red : .primary)
                .accessibilityLabel(low ? "\(part.qty), low stock" : "\(part.qty) in stock")
        }
    }

    var icon: String {
        switch part.params.kind {
        case "R": "line.3.horizontal"
        case "C": "pause"
        case "LED": "lightbulb"
        case "U": "cpu"
        case "J": "cable.connector"
        default: part.category.hasPrefix("Modules") || part.category.hasPrefix("Boards") ? "memorychip" : "shippingbox"
        }
    }
}
