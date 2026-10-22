import PartsKit
import PhotosUI
import SwiftData
import SwiftUI

/// A part's page: everything about it, editable, with stock changes recorded.
struct PartDetailView: View {
    @Bindable var part: Part
    @Environment(\.modelContext) private var ctx
    @Environment(\.openURL) private var openURL
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]
    @State private var photoItem: PhotosPickerItem?
    @State private var countTo = ""
    @State private var newSupplier = "digikey"
    @State private var newPN = ""
    @State private var paramText = ""
    @State private var lookingUp = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("In stock").font(.headline)
                    Spacer()
                    Button { change(-1) } label: { Image(systemName: "minus.circle.fill").font(.title2) }.buttonStyle(.borderless)
                        .accessibilityLabel("Use one")
                    Text("\(part.qty)").font(.title2.monospacedDigit()).frame(minWidth: 56)
                    Button { change(1) } label: { Image(systemName: "plus.circle.fill").font(.title2) }.buttonStyle(.borderless)
                        .accessibilityLabel("Add one")
                }
                HStack {
                    TextField("Counted", text: $countTo).frame(maxWidth: 120)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                    Button("Set count") {
                        if let n = Int(countTo) { Inventory.setQty(part, to: n, in: ctx); countTo = "" }
                    }.disabled(Int(countTo) == nil)
                }
                Picker("Location", selection: $part.location) {
                    Text("None").tag(StorageLocation?.none)
                    ForEach(locations.sorted { $0.path < $1.path }) { l in Text(l.path).tag(Optional(l)) }
                }
                TextField("Low-stock warning at", value: $part.lowStock, format: .number)
            }

            Section("Part") {
                TextField("Manufacturer part number", text: $part.mpn)
                TextField("Manufacturer", text: $part.manufacturer)
                TextField("Description", text: $part.partDescription, axis: .vertical)
                TextField("Category (e.g. Passives/Resistors)", text: $part.category)
                TextField("Package", text: $part.package)
                LabeledContent("Parameters") {
                    Text(part.paramsSummary.isEmpty ? "—" : part.paramsSummary).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Set parameters from text: 10k 1% 0603", text: $paramText)
                    Button("Apply") {
                        part.params = Values.params(from: paramText)
                        if part.package.isEmpty, let p = part.params.pkg { part.package = p }
                        paramText = ""
                    }.disabled(paramText.isEmpty)
                }
                TextField("Tags (comma separated)", text: Binding(get: { part.tags.joined(separator: ", ") },
                                                                set: { part.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
            }

            Section("Datasheet and suppliers") {
                Button { lookingUp = true } label: { Label("Look up online", systemImage: "magnifyingglass") }
                    .disabled(part.mpn.isEmpty && part.suppliers.isEmpty)
                TextField("Datasheet link", text: $part.datasheet)
                if let u = URL(string: part.datasheet), u.scheme?.hasPrefix("http") == true {
                    Link(destination: u) { Label("Open the datasheet", systemImage: "doc.richtext") }
                }
                ForEach(Array(part.suppliers.enumerated()), id: \.offset) { i, s in
                    HStack {
                        Text(Supplier.named(s.supplier)?.name ?? s.supplier).foregroundStyle(.secondary)
                        Spacer()
                        if let price = s.breaks.first {
                            Text("\(price.unit.formatted(.currency(code: s.currency ?? "USD").precision(.significantDigits(1...4)))) · \((s.stock ?? 0).formatted()) in stock")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let u = URL(string: s.url), !s.url.isEmpty { Link(s.pn, destination: u) }
                        else if let u = Supplier.named(s.supplier)?.search(s.pn) { Link(s.pn, destination: u) } else { Text(s.pn) }
                    }
                    .swipeActions { Button("Remove", role: .destructive) { var l = part.suppliers; l.remove(at: i); part.suppliers = l } }
                }
                HStack {
                    Picker("Supplier", selection: $newSupplier) { ForEach(Supplier.all) { Text($0.name).tag($0.id) } }.labelsHidden().fixedSize()
                    TextField("Supplier part number", text: $newPN)
                    Button("Add") {
                        var l = part.suppliers; l.append(SupplierEntry(supplier: newSupplier, pn: newPN.trimmingCharacters(in: .whitespaces))); part.suppliers = l; newPN = ""
                    }.disabled(newPN.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !part.mpn.isEmpty {
                    DisclosureGroup("Search for \(part.mpn)") {
                        ForEach(Identify.searchLinks(part.mpn)) { l in Link(l.name, destination: l.url) }
                    }
                }
            }

            Section("Photos") {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(part.sortedPhotos) { ph in
                            if let d = ph.data, let img = Image(data: d) {
                                img.resizable().scaledToFill().frame(width: 120, height: 120).clipShape(.rect(cornerRadius: 8))
                                    .contextMenu { Button("Delete photo", role: .destructive) { ctx.delete(ph) } }
                            }
                        }
                    }
                }
                PhotosPicker(selection: $photoItem, matching: .images) { Label("Add a photo", systemImage: "photo.badge.plus") }
            }

            Section("Notes") {
                TextField("Notes", text: $part.notes, axis: .vertical).lineLimit(3...10)
            }

            Section("History") {
                let changes = (part.history ?? []).sorted { $0.at > $1.at }
                if changes.isEmpty { Text("No stock changes yet.").foregroundStyle(.secondary) }
                ForEach(changes.prefix(30)) { c in
                    HStack {
                        Text(c.delta > 0 ? "+\(c.delta)" : "\(c.delta)").monospacedDigit().foregroundStyle(c.delta > 0 ? .green : .orange).frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(c.reason.isEmpty ? "Change" : c.reason)
                            Text(c.at, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let a = c.qtyAfter { Text("→ \(a)").foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(part.title)
        .sheet(isPresented: $lookingUp) {
            SupplierLookupView(query: part.mpn.isEmpty ? part.suppliers.first?.pn ?? "" : part.mpn) { Inventory.fill(part, from: $0) }
        }
        .onChange(of: part.mpn) { part.updated = .now }
        .onChange(of: part.partDescription) { part.updated = .now }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let raw = try? await item.loadTransferable(type: Data.self), let jpeg = Images.jpeg(raw) {
                    let ph = PartPhoto(data: jpeg)
                    ctx.insert(ph)
                    ph.part = part
                    part.updated = .now
                }
                photoItem = nil
            }
        }
    }

    func change(_ d: Int) { Inventory.adjust(part, by: d, reason: d > 0 ? "Added" : "Used", in: ctx) }
}
