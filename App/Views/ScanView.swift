import PartsKit
import SwiftData
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// Scanning bag labels: the camera (live, on iPhone and iPad), a USB or Bluetooth scanner that types
/// into the box, or pasted text. A label with no code? Identify what's in view instead.
struct ScanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var ctx
    @State private var typed = ""
    @State private var found: BagLabel?
    @State private var recent: [String] = []
    @State private var message = ""
    #if os(iOS)
    @State private var scanner = ScannerBridge()
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                #if os(iOS)
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    LiveScanner(bridge: scanner) { payload in handle(payload) }
                        .clipShape(.rect(cornerRadius: 16))
                        .overlay(alignment: .bottom) {
                            Button {
                                Task {
                                    if let d = await scanner.capture() { app.photoForIdentify = d; app.tab = .identify }
                                }
                            } label: { Label("Identify what’s in view", systemImage: "camera.viewfinder") }
                                .buttonStyle(.borderedProminent).padding()
                        }
                } else {
                    unavailable
                }
                #else
                unavailable
                #endif
                TextField("Scanner input or pasted label text", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { handle(typed); typed = "" }
                    .autocorrectionDisabled()
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            .padding()
            .navigationTitle("Scan a bag label")
            .sheet(item: Binding(get: { found.map(FoundLabel.init) }, set: { found = $0?.label })) { f in ReceiveSheet(label: f.label) }
        }
    }

    var unavailable: some View {
        ContentUnavailableView {
            Label("Scan with a photo or a scanner", systemImage: "barcode.viewfinder")
        } description: {
            Text("Digi-Key, Mouser and LCSC bag labels are read from a photo in Identify, or typed in by a USB barcode scanner below.")
        } actions: {
            Button("Identify from a photo") { app.tab = .identify }
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

#if os(iOS)
/// Lets SwiftUI ask the live scanner for a photo.
@Observable
final class ScannerBridge {
    weak var controller: DataScannerViewController?
    func capture() async -> Data? {
        guard let c = controller, let img = try? await c.capturePhoto() else { return nil }
        return img.jpegData(compressionQuality: 0.9)
    }
}

/// VisionKit's live scanner, looking for 2-D codes and barcodes.
struct LiveScanner: UIViewControllerRepresentable {
    let bridge: ScannerBridge
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.dataMatrix, .qr, .code128, .code39, .pdf417, .microQR])],
                                           qualityLevel: .accurate, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                           isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        bridge.controller = vc
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) { vc.stopScanning() }
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items { if let p = b.payloadStringValue { onCode(p) } }
        }
        func dataScanner(_ s: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let b) = item, let p = b.payloadStringValue { onCode(p) }
        }
    }
}

/// The system camera, for a still photo.
struct CameraPicker: UIViewControllerRepresentable {
    var onPhoto: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let d = img.jpegData(compressionQuality: 0.9) { parent.onPhoto(d) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif
