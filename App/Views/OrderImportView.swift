import PartsKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Import Digi-Key and Mouser orders: pick orders from your order history (through their APIs), then the items
/// to bring in. Each item is looked up for its full description, package and datasheet, and the ticked ones go
/// into stock together, with the order number in each part's history. An order file (CSV, Excel — LCSC's too)
/// or a table copied from a supplier's website can be read instead.
struct OrderImportView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]

    enum Step: Equatable { case history, file, items, done(String) }
    @State private var step: Step = .file

    // Your orders
    @State private var supplier = "digikey"
    @State private var period = 90
    @State private var history: [OrderSummary] = []
    @State private var listed = ""            // "<supplier>:<period>" the list is for
    @State private var picked = Set<String>()
    @State private var imported = Set<String>()

    // The items
    @State private var orders: [SupplierOrder] = []
    @State private var fileName = ""
    @State private var chosen = Set<String>()
    @State private var details: [String: SupplierProduct] = [:]
    @State private var lookups: Task<Void, Never>?
    @State private var lookingUp = 0
    @State private var locationID: String?
    @State private var fill = true

    @State private var choosingFile = false
    @State private var targeted = false
    @State private var error = ""
    @State private var progress = ""
    @State private var working = false

    private var keys: SupplierKeys { SupplierKeys.shared }
    private var hasHistory: Bool { Self.debugHistory != nil || keys.canListDigiKeyOrders || keys.canListMouserOrders }
    /// Orders to list instead of asking the suppliers (the -orderHistory launch option).
    static nonisolated(unsafe) var debugHistory: [OrderSummary]?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .history: historyList
                case .file: start
                case .items: items
                case .done(let said): finished(said)
                }
            }
            .navigationTitle(title)
            .toolbar { toolbar }
        }
        .frame(minWidth: 780, minHeight: 660)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: Self.types) { result in
            guard case .success(let u) = result else { return }
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: u) { read(d, name: u.lastPathComponent) }
        }
        .onAppear {
            fill = keys.isConfigured
            imported = Inventory.importedOrders(in: ctx)
            if let (d, name) = app.orderToImport { app.orderToImport = nil; read(d, name: name); return }
            if hasHistory {
                supplier = keys.canListDigiKeyOrders || Self.debugHistory != nil ? "digikey" : "mouser"
                step = .history
            }
        }
        .task(id: step == .history ? "\(supplier):\(period)" : "") {
            if step == .history, listed != "\(supplier):\(period)" { await loadHistory() }
        }
        .onDisappear { lookups?.cancel() }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(isDone ? "Close" : "Cancel") { dismiss() }.disabled(working)
        }
        switch step {
        case .history:
            ToolbarItem(placement: .confirmationAction) {
                Button(picked.count > 1 ? "Show Items of \(picked.count) Orders" : "Show Items") { Task { await showItems() } }
                    .disabled(picked.isEmpty || working)
            }
        case .items:
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { back() }.disabled(working)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add \(chosen.count) to Stock") { Task { await add() } }
                    .disabled(chosen.isEmpty || working)
            }
        default: ToolbarItem { EmptyView() }
        }
    }

    var isDone: Bool { if case .done = step { true } else { false } }

    static let types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .html, .spreadsheet,
                                  UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "xls")].compactMap { $0 }

    var title: String {
        switch step {
        case .history: return "Your Orders"
        case .file, .done: return "Import an Order"
        case .items:
            if orders.count == 1, let o = orders.first {
                let who = Supplier.named(o.supplier ?? "")?.name
                return [who, o.number.isEmpty ? "order" : "order \(o.number)"].compactMap { $0 }.joined(separator: " ")
            }
            return "\(orders.count) Orders"
        }
    }

    // MARK: Your orders

    var historyList: some View {
        VStack(spacing: 0) {
            HStack {
                if keys.canListDigiKeyOrders && keys.canListMouserOrders {
                    Picker("Supplier", selection: $supplier) {
                        Text("Digi-Key").tag("digikey")
                        Text("Mouser").tag("mouser")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if supplier == "digikey" {
                    Picker("Placed in", selection: $period) {
                        Text("the last 30 days").tag(30)
                        Text("the last 90 days").tag(90)
                        Text("the last year").tag(365)
                        Text("the last 3 years").tag(1095)
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadHistory() } }.disabled(working)
                Button("From a File…", systemImage: "doc") { error = ""; step = .file }
            }
            .padding()
            Divider()
            if working && history.isEmpty {
                ProgressView(progress.isEmpty ? "Asking \(Supplier.named(supplier)?.name ?? supplier) for your orders…" : progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !error.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't list the orders", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await loadHistory() } }
                }
            } else if history.isEmpty {
                ContentUnavailableView("No orders", systemImage: "shippingbox",
                                       description: Text(supplier == "digikey" ? "Digi-Key has no orders on this account in that time. Try a longer one." : "Mouser has no orders on this account."))
            } else {
                List {
                    Section {
                        ForEach(history) { o in
                            OrderSummaryRow(order: o, imported: imported.contains(o.number),
                                            on: Binding(get: { picked.contains(o.id) }, set: { if $0 { picked.insert(o.id) } else { picked.remove(o.id) } }))
                        }
                    } header: {
                        Text("\(history.count) orders — tick the ones to bring in, then Show Items")
                    }
                }
                if working, !progress.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text(progress).foregroundStyle(.secondary) }.padding(8)
                }
            }
        }
    }

    func loadHistory() async {
        let key = "\(supplier):\(period)"
        working = true; error = ""; progress = ""
        defer { working = false }
        do {
            let found = Self.debugHistory != nil ? Self.debugHistory ?? [] : supplier == "digikey"
                ? try await keys.digikeyOrders(since: .now.addingTimeInterval(-Double(period) * 86_400))
                : try await keys.mouserOrders.orders()
            guard key == "\(supplier):\(period)" else { return }   // the choice changed meanwhile
            history = found
            picked = picked.filter { id in found.contains { $0.id == id } }
            listed = key
        } catch is CancellationError {
        } catch {
            history = []; self.error = error.localizedDescription
        }
    }

    /// The picked orders' lines (fetched for Mouser), then on to the items.
    func showItems() async {
        working = true; error = ""
        defer { working = false; progress = "" }
        var out: [SupplierOrder] = []
        for s in history where picked.contains(s.id) {
            if let o = s.order { out.append(o); continue }
            progress = "Reading \(s.supplierName) order \(s.number)…"
            do { out.append(try await keys.mouserOrders.order(s.number)) } catch { self.error = error.localizedDescription; return }
        }
        fileName = ""
        set(out)
    }

    // MARK: From a file

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
                if hasHistory { Button("Your Orders", systemImage: "list.bullet") { error = ""; step = .history } }
            }
            .controlSize(.large)
            if !error.isEmpty {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }
            if !hasHistory {
                Text("To pick from your Digi-Key and Mouser orders here instead, add your Digi-Key account number or a Mouser Order History key in Settings › Supplier lookups.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
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
            fileName = name; set([o])
        } catch {
            self.error = "\(name): \(error.localizedDescription)"
            step = .file
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
        do { fileName = ""; set([try SupplierOrder.read(text: text)]) } catch { self.error = error.localizedDescription }
    }

    func back() {
        lookups?.cancel()
        orders = []; details = [:]; chosen = []
        step = hasHistory && fileName.isEmpty ? .history : .file
    }

    // MARK: The items

    static func key(_ order: Int, _ line: Int) -> String { "\(order)-\(line)" }

    func set(_ o: [SupplierOrder]) {
        error = ""; orders = o; details = [:]
        chosen = Set(o.enumerated().flatMap { i, order in order.lines.map { Self.key(i, $0.id) } })
        step = .items
        lookUpDetails()
    }

    /// Each line's listing at Digi-Key or Mouser, for its full description, package and datasheet.
    func lookUpDetails() {
        lookups?.cancel()
        guard keys.isConfigured else { return }
        let lookup = keys.lookup
        let todo = orders.enumerated().flatMap { i, o in o.lines.map { (Self.key(i, $0.id), $0) } }
        lookingUp = todo.count
        lookups = Task {
            await withTaskGroup(of: (String, SupplierProduct?).self) { group in
                var next = 0
                func queue() {
                    guard next < todo.count else { return }
                    let (k, line) = todo[next]; next += 1
                    group.addTask { (k, await Self.listing(for: line, lookup: lookup)) }
                }
                for _ in 0..<4 { queue() }
                for await (k, p) in group {
                    if Task.isCancelled { break }
                    if let p { details[k] = p }
                    lookingUp -= 1
                    queue()
                }
            }
            lookingUp = 0
        }
    }

    /// The listing that is this line: the same supplier or maker number, the line's own supplier first.
    nonisolated static func listing(for line: SupplierOrder.Line, lookup: SupplierLookup) async -> SupplierProduct? {
        let numbers = [line.mpn, line.spn].filter { !$0.isEmpty }
        guard let first = numbers.first else { return nil }
        let found = await lookup.lookup(first).products
        let same = { (p: SupplierProduct) in numbers.contains { $0.caseInsensitiveCompare(p.mpn) == .orderedSame || $0.caseInsensitiveCompare(p.spn) == .orderedSame } }
        return found.first { same($0) && $0.supplier == line.supplier } ?? found.first(where: same)
    }

    var allKeys: [String] { orders.enumerated().flatMap { i, o in o.lines.map { Self.key(i, $0.id) } } }

    var items: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(orders.enumerated()), id: \.offset) { i, order in
                    Section {
                        ForEach(order.lines) { l in
                            let k = Self.key(i, l.id)
                            OrderLineRow(line: l, existing: Inventory.match(l, in: ctx), currency: order.currency, listing: details[k],
                                         on: Binding(get: { chosen.contains(k) }, set: { if $0 { chosen.insert(k) } else { chosen.remove(k) } }))
                        }
                    } header: {
                        HStack {
                            Text(header(order))
                            Spacer()
                            let mine = order.lines.map { Self.key(i, $0.id) }
                            let all = mine.allSatisfy(chosen.contains)
                            Button(all ? "None" : "All") { if all { chosen.subtract(mine) } else { chosen.formUnion(mine) } }
                                .buttonStyle(.borderless)
                        }
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
                Toggle("Fill in details from Digi-Key and Mouser: description, datasheet, package, parameters (only what a part doesn't have yet)", isOn: $fill)
                    .disabled(!keys.isConfigured)
                if !keys.isConfigured {
                    Text("Add supplier keys in Settings to fill in details.").font(.caption).foregroundStyle(.secondary)
                }
                if !progress.isEmpty || lookingUp > 0 {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(progress.isEmpty ? "Looking up \(lookingUp) items at Digi-Key and Mouser…" : progress).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 160)
        }
    }

    func header(_ o: SupplierOrder) -> String {
        let who = Supplier.named(o.supplier ?? "")?.name ?? "Order"
        var s = o.number.isEmpty ? who : "\(who) order \(o.number)"
        s += " — \(o.lines.count) lines, \(o.lines.reduce(0) { $0 + $1.qty }) parts"
        if imported.contains(o.number) { s += " — already imported once" }
        if !fileName.isEmpty { s += " — \(fileName)" }
        return s
    }

    func add() async {
        working = true
        defer { working = false; progress = "" }
        let location = locationID.flatMap { id in locations.first { $0.uid == id } }
        let lookup = keys.lookup
        var lines = 0, qty = 0, added = 0, updated = 0, filled = 0, datasheets = 0
        for (i, order) in orders.enumerated() {
            let picked = order.lines.filter { chosen.contains(Self.key(i, $0.id)) }
            guard !picked.isEmpty else { continue }
            let r = Inventory.receive(order, lines: picked, location: location, in: ctx)
            lines += picked.count; qty += picked.reduce(0) { $0 + $1.qty }; added += r.added; updated += r.updated
            guard fill, keys.isConfigured else { continue }
            for l in picked {
                guard let part = r.parts[l.id] else { continue }
                let k = Self.key(i, l.id)
                var listing = details[k]
                if listing == nil {
                    progress = "Looking up \(l.partNumber)…"
                    listing = await Self.listing(for: l, lookup: lookup)
                }
                guard let listing else { continue }
                let hadSheet = !part.datasheet.isEmpty
                Inventory.fill(part, from: listing); filled += 1
                if !hadSheet && !part.datasheet.isEmpty { datasheets += 1 }
            }
        }
        try? ctx.save()
        var said = "Added \(qty) parts from \(lines) lines: \(added) new, \(updated) added to parts you had."
        if fill && keys.isConfigured { said += " \(filled) were filled in from Digi-Key and Mouser, \(datasheets) with a datasheet." }
        imported = Inventory.importedOrders(in: ctx)
        step = .done(said)
    }

    func finished(_ said: String) -> some View {
        ContentUnavailableView {
            Label(orders.count > 1 ? "Orders added" : "Order added", systemImage: "checkmark.circle")
        } description: {
            Text(said)
        } actions: {
            Button("Show Parts") { app.tab = .parts; dismiss() }
            Button("Import More") { orders = []; details = [:]; fileName = ""; picked = []; step = hasHistory ? .history : .file }
        }
    }
}

/// An order in the order history: ticked to bring in.
struct OrderSummaryRow: View {
    let order: OrderSummary
    let imported: Bool
    @Binding var on: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: $on).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(order.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Undated").font(.headline)
                    Text("Sales order \(order.number)").foregroundStyle(.secondary)
                    if imported {
                        Text("Imported").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.green.opacity(0.18), in: .capsule).foregroundStyle(.green)
                    }
                }
                HStack(spacing: 6) {
                    if !order.status.isEmpty { Text(order.status) }
                    if let o = order.order {
                        Text("· \(o.lines.count) lines, \(o.lines.reduce(0) { $0 + $1.qty }) parts")
                        Text("· " + o.lines.prefix(3).map(\.partNumber).joined(separator: ", ") + (o.lines.count > 3 ? "…" : "")).lineLimit(1)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let t = order.total {
                Text(t, format: .currency(code: order.currency ?? "USD")).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { on.toggle() }
    }
}

/// One line of the order: ticked to add, what it is (with its listing's description and datasheet once looked
/// up), and what adding it will do.
struct OrderLineRow: View {
    let line: SupplierOrder.Line
    let existing: Part?
    let currency: String?
    var listing: SupplierProduct?
    @Binding var on: Bool

    var description: String {
        let own = line.description
        guard let l = listing else { return own }
        let theirs = l.detail.isEmpty ? l.description : l.detail
        return theirs.count > own.count ? theirs : own
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: $on).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(line.partNumber).font(.headline)
                    let maker = line.manufacturer.isEmpty ? (listing?.manufacturer ?? "") : line.manufacturer
                    if !maker.isEmpty { Text(maker).foregroundStyle(.secondary) }
                    if let pkg = listing?.normalisedPackage, !pkg.isEmpty { Text(pkg).font(.caption).foregroundStyle(.secondary) }
                }
                if !description.isEmpty { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 12) {
                    Group {
                        if let p = existing {
                            Label("Adds to \(p.title) — you have \(p.qty)" + (p.location.map { ", in \($0.path)" } ?? ""), systemImage: "plus.circle")
                        } else {
                            Label("New part", systemImage: "sparkle")
                        }
                    }
                    .foregroundStyle(existing == nil ? Color.accentColor : .secondary)
                    if let sheet = listing?.datasheet, let u = URL(string: sheet) {
                        Link(destination: u) { Label("Datasheet", systemImage: "doc.richtext") }
                    }
                    if let page = listing?.url, let u = URL(string: page), !page.isEmpty {
                        Link(destination: u) { Label(listing?.supplierName ?? "Listing", systemImage: "safari") }
                    }
                }
                .font(.caption)
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
