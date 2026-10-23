import PartsKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Import a Digi-Key, Mouser or LCSC order: the file their order history downloads (CSV, Excel) or the order's
/// table copied from their website. Each line is shown with what it will do — add to a part you have, or make
/// a new one — and the ones ticked go into stock together, with the order number in each part's history.
struct OrderImportView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]
    @State private var order: SupplierOrder?
    @State private var fileName = ""
    @State private var error = ""
    @State private var chosen = Set<Int>()
    @State private var locationID: String?
    @State private var lookUp = true
    @State private var choosingFile = false
    @State private var targeted = false
    @State private var progress = ""
    @State private var working = false
    @State private var done: String?

    var body: some View {
        NavigationStack {
            Group {
                if let done {
                    finished(done)
                } else if let order {
                    lines(order)
                } else {
                    start
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done == nil ? "Cancel" : "Close") { dismiss() }.disabled(working) }
                if order != nil && done == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(chosen.count) to Stock") { Task { await add() } }
                            .disabled(chosen.isEmpty || working)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 640)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: Self.types) { result in
            guard case .success(let u) = result else { return }
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: u) { read(d, name: u.lastPathComponent) }
        }
        .onAppear {
            lookUp = SupplierKeys.shared.isConfigured
            if let (d, name) = app.orderToImport { read(d, name: name); app.orderToImport = nil }
        }
    }

    static let types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .html, .spreadsheet,
                                  UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "xls")].compactMap { $0 }

    var title: String {
        guard let order else { return "Import an Order" }
        let who = Supplier.named(order.supplier ?? "")?.name
        return [who, order.number.isEmpty ? "order" : "order \(order.number)"].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Choosing the order

    var start: some View {
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label("Add a whole order", systemImage: "shippingbox.and.arrow.backward")
            } description: {
                Text("Download the order from your order history at Digi-Key, Mouser or LCSC (CSV or Excel) and choose it here, or drop it here. You can also copy the order's table from their website and paste it.")
            }
            HStack {
                Button("Choose File…", systemImage: "doc") { choosingFile = true }
                Button("Paste", systemImage: "doc.on.clipboard") { paste() }
            }
            .controlSize(.large)
            if !error.isEmpty {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }
            DisclosureGroup("Where to find the order file") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("**Digi-Key:** sign in › Order History › open the order › **Download** (CSV or Excel).")
                    Text("**Mouser:** sign in › Order History › open the order › **Export** (Excel or CSV).")
                    Text("**LCSC:** Orders › the order › **Export** (Excel).")
                    Text("Or select the table of parts on the order's page, copy it, and choose Paste.")
                }
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 520)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first, let d = try? Data(contentsOf: u) else { return false }
            read(d, name: u.lastPathComponent)
            return true
        } isTargeted: { targeted = $0 }
    }

    func read(_ data: Data, name: String) {
        do {
            let o = try SupplierOrder.read(data, fileName: name)
            fileName = name; set(o)
        } catch {
            self.error = "\(name): \(error.localizedDescription)"
        }
    }

    func paste() {
        #if os(macOS)
        let pb = NSPasteboard.general
        let text = pb.string(forType: .html) ?? pb.string(forType: .tabularText) ?? pb.string(forType: .string)
        #else
        let text = UIPasteboard.general.string
        #endif
        guard let text, !text.isEmpty else { error = "There's no text on the clipboard. Copy the order's table first."; return }
        do { fileName = ""; set(try SupplierOrder.read(text: text)) } catch { self.error = error.localizedDescription }
    }

    func set(_ o: SupplierOrder) {
        error = ""; order = o; chosen = Set(o.lines.map(\.id))
    }

    // MARK: The lines

    func lines(_ order: SupplierOrder) -> some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(order.lines) { l in
                        OrderLineRow(line: l, existing: Inventory.match(l, in: ctx), currency: order.currency,
                                     on: Binding(get: { chosen.contains(l.id) }, set: { if $0 { chosen.insert(l.id) } else { chosen.remove(l.id) } }))
                    }
                } header: {
                    HStack {
                        Text("\(order.lines.count) lines, \(order.lines.reduce(0) { $0 + $1.qty }) parts" + (fileName.isEmpty ? "" : " — \(fileName)"))
                        Spacer()
                        Button(chosen.count == order.lines.count ? "None" : "All") {
                            chosen = chosen.count == order.lines.count ? [] : Set(order.lines.map(\.id))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Divider()
            Form {
                Picker("Put new parts in", selection: $locationID) {
                    Text("No location").tag(String?.none)
                    ForEach(locations.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) { l in
                        Text(l.path).tag(Optional(l.uid))
                    }
                }
                Toggle("Fill in new parts from Digi-Key and Mouser (datasheet, package, parameters)", isOn: $lookUp)
                    .disabled(!SupplierKeys.shared.isConfigured)
                if !SupplierKeys.shared.isConfigured {
                    Text("Add supplier keys in Settings to fill in details.").font(.caption).foregroundStyle(.secondary)
                }
                if !progress.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text(progress).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 150)
        }
    }

    func add() async {
        guard let order else { return }
        working = true
        defer { working = false; progress = "" }
        let location = locationID.flatMap { id in locations.first { $0.uid == id } }
        let picked = order.lines.filter { chosen.contains($0.id) }
        let r = Inventory.receive(order, lines: picked, location: location, in: ctx)
        var filled = 0
        if lookUp, SupplierKeys.shared.isConfigured {
            let lookup = SupplierKeys.shared.lookup
            for (i, p) in r.newParts.enumerated() {
                progress = "Looking up \(p.title) (\(i + 1) of \(r.newParts.count))…"
                let numbers = [p.mpn] + p.suppliers.map(\.pn)
                let found = await lookup.lookup(p.mpn.isEmpty ? (p.suppliers.first?.pn ?? "") : p.mpn).products
                if let best = found.first(where: { prod in numbers.contains { $0.caseInsensitiveCompare(prod.mpn) == .orderedSame || $0.caseInsensitiveCompare(prod.spn) == .orderedSame } }) {
                    Inventory.fill(p, from: best); filled += 1
                }
            }
            try? ctx.save()
        }
        var said = "Added \(picked.reduce(0) { $0 + $1.qty }) parts from \(picked.count) lines: \(r.added) new, \(r.updated) added to parts you had."
        if lookUp && !r.newParts.isEmpty { said += " \(filled) of the new parts were filled in from Digi-Key and Mouser." }
        done = said
    }

    func finished(_ said: String) -> some View {
        ContentUnavailableView {
            Label("Order added", systemImage: "checkmark.circle")
        } description: {
            Text(said)
        } actions: {
            Button("Show Parts") { app.tab = .parts; dismiss() }
            Button("Import Another") { order = nil; done = nil; fileName = "" }
        }
    }
}

/// One line of the order: ticked to add, what it is, and what adding it will do.
struct OrderLineRow: View {
    let line: SupplierOrder.Line
    let existing: Part?
    let currency: String?
    @Binding var on: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: $on).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(line.partNumber).font(.headline)
                    if !line.manufacturer.isEmpty { Text(line.manufacturer).foregroundStyle(.secondary) }
                }
                if !line.description.isEmpty { Text(line.description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Group {
                    if let p = existing {
                        Label("Adds to \(p.title) — you have \(p.qty)" + (p.location.map { ", in \($0.path)" } ?? ""), systemImage: "plus.circle")
                    } else {
                        Label("New part", systemImage: "sparkle")
                    }
                }
                .font(.caption).foregroundStyle(existing == nil ? Color.accentColor : .secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("× \(line.qty)").font(.body.monospacedDigit())
                if let u = line.unitPrice {
                    Text(u, format: .currency(code: currency ?? "USD").precision(.fractionLength(2...5))).font(.caption).foregroundStyle(.secondary)
                }
                if !line.spn.isEmpty && !line.mpn.isEmpty { Text(line.spn).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .opacity(on ? 1 : 0.5)
    }
}

#if os(macOS)
/// File › Import Supplier Order…
struct OrderImportCommands: Commands {
    let app: AppModel
    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import Supplier Order…") { app.importingOrder = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}
#endif
