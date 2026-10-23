import PartsKit
import SwiftData
import SwiftUI

/// Scanning bag labels: the camera (built in, Continuity Camera, or plugged in — pick which), a USB or
/// Bluetooth scanner that types into the box, or pasted text. A label with no code? Identify what's in view instead.
struct ScanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var ctx
    @State private var typed = ""
    @State private var found: BagLabel?
    @State private var recent: [String] = []
    @State private var message = ""
    @State private var camera = Camera()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if camera.state == .noCamera {
                    unavailable
                } else {
                    CameraView(camera: camera, shutterTitle: "Identify what’s in view") { d in
                        app.photoForIdentify = d; app.tab = .identify
                    }
                }
                TextField("Scanner input or pasted label text", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { handle(typed); typed = "" }
                    .autocorrectionDisabled()
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            .padding()
            .navigationTitle("Scan a bag label")
            .task {
                camera.scanning = true
                camera.onCode = { handle($0) }
                await camera.start()
            }
            .onDisappear { camera.stop() }
            .sheet(item: Binding(get: { found.map(FoundLabel.init) }, set: { found = $0?.label })) { f in ReceiveSheet(label: f.label) }
        }
    }

    var unavailable: some View {
        ContentUnavailableView {
            Label("Scan with a photo or a scanner", systemImage: "barcode.viewfinder")
        } description: {
            Text("Connect a camera, or read Digi-Key, Mouser and LCSC bag labels from a photo in Identify, or type them in with a USB barcode scanner below.")
        } actions: {
            Button("Identify from a photo") { app.tab = .identify }
            Button("Import a whole order…") { app.importingOrder = true }
        }
    }

    func handle(_ payload: String) {
        let p = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, found == nil, !recent.contains(p) else { return }
        let l = BagLabels.parse(p)
        if l.hasPart {
            recent.append(p); if recent.count > 20 { recent.removeFirst() }
            found = l
        } else if let q = l.qty {
            message = "Read a quantity (\(q)) — scan the 2-D code on the label for the part."
        }
    }
}

private struct FoundLabel: Identifiable { let label: BagLabel; var id: String { label.raw } }

/// Confirm a scanned bag: the part it matches (or a new one), the quantity, and where it goes.
struct ReceiveSheet: View {
    let label: BagLabel
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]
    @State private var qty = 0
    @State private var location: StorageLocation?

    var existing: Part? { Inventory.find(spn: label.spn, supplier: label.supplier, mpn: label.mpn, manufacturer: label.manufacturer, in: ctx) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Supplier", value: Supplier.named(label.supplier ?? "")?.name ?? "—")
                    if !label.mpn.isEmpty { LabeledContent("Part number", value: label.mpn) }
                    if !label.spn.isEmpty { LabeledContent("Supplier number", value: label.spn) }
                    if !label.manufacturer.isEmpty { LabeledContent("Manufacturer", value: label.manufacturer) }
                    if !label.salesOrder.isEmpty { LabeledContent("Order", value: label.salesOrder) }
                    if !label.lot.isEmpty { LabeledContent("Lot", value: label.lot) }
                }
                Section {
                    if let p = existing {
                        Label("Adds to \(p.title) (\(p.qty) in stock)", systemImage: "plus.circle")
                    } else {
                        Label("A new part", systemImage: "sparkles")
                        Picker("Location", selection: $location) {
                            Text("None").tag(StorageLocation?.none)
                            ForEach(locations.sorted { $0.path < $1.path }) { l in Text(l.path).tag(Optional(l)) }
                        }
                    }
                    Stepper("Quantity: \(qty)", value: $qty, in: 0...1_000_000)
                }
                if !label.fields.isEmpty {
                    DisclosureGroup("Everything on the label") {
                        ForEach(label.fields, id: \.di) { f in LabeledContent(f.name, value: f.value) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Receive")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add part" : "Add stock") {
                        if let r = Inventory.receive(label, qty: qty, location: location, in: ctx) { app.partToShow = r.part.uid }
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 440)
        .onAppear { qty = label.qty ?? 1 }
    }
}
