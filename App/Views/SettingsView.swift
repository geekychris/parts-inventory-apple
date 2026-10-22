import CloudKit
import PartsKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var parts: [Part]
    @AppStorage("defaultLowStock") private var defaultLow = 0
    @AppStorage("currency") private var currency = "USD"
    @State private var iCloud = "Checking…"
    @State private var importing = false
    @State private var exporting = false
    @State private var exportPhotos = true
    @State private var exportDoc: JSONFile?
    @State private var result = ""
    @AppStorage(Camera.chosenKey) private var cameraID = ""
    @State private var cameras: [CameraDevice] = []
    @State private var dkID = ""
    @State private var dkSecret = ""
    @State private var mouserKey = ""
    @State private var keyTest: [String: String?] = [:]
    @State private var testing = false

    var body: some View {
        Form {
            Section("iCloud") {
                LabeledContent("Sync", value: PartsInventoryApp.syncsWithICloud ? "On — your private iCloud database" : "Off — stored on this device only")
                LabeledContent("Account", value: iCloud)
            }
            Section("Stock") {
                Stepper("Low-stock warning at \(defaultLow) (0 = off)", value: $defaultLow, in: 0...10_000)
                TextField("Currency", text: $currency)
            }
            Section {
                Button { importing = true } label: { Label("Import a backup…", systemImage: "square.and.arrow.down") }
                Toggle("Include photos in exports", isOn: $exportPhotos)
                Button {
                    if let d = try? Inventory.backup(in: ctx, photos: exportPhotos).encoded() { exportDoc = JSONFile(data: d); exporting = true }
                } label: { Label("Export a backup…", systemImage: "square.and.arrow.up") }
                if !result.isEmpty { Text(result).font(.callout).foregroundStyle(.secondary) }
            } header: { Text("Backup") } footer: {
                Text("The same file as the web version (geekychris.github.io/tools/parts-inventory). Importing merges by id: new items are added, items in both keep the newer one, nothing is deleted.")
            }
            Section {
                Picker("Camera", selection: $cameraID) {
                    Text("Automatic").tag("")
                    ForEach(cameras) { c in Text("\(c.name) — \(c.kind)").tag(c.id) }
                    if !cameraID.isEmpty, !cameras.contains(where: { $0.id == cameraID }) { Text("Not connected").tag(cameraID) }
                }
            } header: { Text("Camera") } footer: {
                Text("Used by Scan and Identify; you can also switch there. Automatic prefers a plugged-in or Continuity camera.")
            }
            Section {
                TextField("Digi-Key client ID", text: $dkID).autocorrectionDisabled()
                SecureField("Digi-Key client secret", text: $dkSecret)
                SecureField("Mouser Search API key", text: $mouserKey)
                HStack {
                    Button(testing ? "Testing…" : "Save and test") { Task { await saveAndTest() } }
                        .disabled(testing || !keysChanged && dkID.isEmpty && mouserKey.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                }
                ForEach(keyTest.sorted { $0.key < $1.key }, id: \.key) { id, err in
                    Label(err ?? "\(Supplier.named(id)?.name ?? id) works", systemImage: err == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(err == nil ? .green : .orange).font(.callout)
                }
            } header: { Text("Supplier lookups") } footer: {
                Text("Free keys look part numbers up at Digi-Key and Mouser: stock, prices, datasheets and parameters. Digi-Key: sign in at [developer.digikey.com](https://developer.digikey.com), make an organisation, then a production app subscribed to Product Information V4. Mouser: sign in, then [mouser.com/api-hub](https://www.mouser.com/api-hub/) › Search API. Keys are kept in the Keychain.")
            }
            APISettingsSection()
            Section("Recognition") {
                LabeledContent("Apple Intelligence", value: AppleIntelligence.status)
                LabeledContent("Recognising by look", value: LookModel.isAvailable ? "MobileCLIP, on this device" : "Not in this build")
                LabeledContent("Built-in parts list", value: "\(Catalog.shared.entries.count) parts, \(Catalog.shared.generic.count) kinds")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await checkAccount() }
        .task { cameras = Camera.available() }
        .task {
            let k = SupplierKeys.shared
            dkID = k.digikeyID; dkSecret = k.digikeySecret; mouserKey = k.mouserKey
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            guard case .success(let url) = r else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do {
                let (b, warnings) = try Backup.read(Data(contentsOf: url))
                let r = Inventory.merge(b, warnings: warnings, in: ctx)
                result = "Imported: \(r.added) added, \(r.updated) updated, \(r.kept) kept (newer here), \(r.photos) photos." + (r.warnings.isEmpty ? "" : " " + r.warnings.joined(separator: " "))
            } catch { result = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .json, defaultFilename: "parts-inventory-\(Date.now.formatted(.iso8601.year().month().day())).json") { r in
            if case .success = r { result = "Exported \(parts.count) parts." }
        }
    }

    var keysChanged: Bool {
        let k = SupplierKeys.shared
        return dkID != k.digikeyID || dkSecret != k.digikeySecret || mouserKey != k.mouserKey
    }

    func saveAndTest() async {
        SupplierKeys.shared.save(digikeyID: dkID, digikeySecret: dkSecret, mouserKey: mouserKey)
        testing = true
        keyTest = await SupplierKeys.shared.lookup.test()
        testing = false
    }

    func checkAccount() async {
        guard PartsInventoryApp.syncsWithICloud else { iCloud = "—"; return }
        do {
            switch try await CKContainer(identifier: PartsInventoryApp.cloudContainer).accountStatus() {
            case .available: iCloud = "Signed in"
            case .noAccount: iCloud = "Not signed in to iCloud"
            case .restricted: iCloud = "Restricted"
            case .temporarilyUnavailable: iCloud = "Temporarily unavailable"
            default: iCloud = "Unknown"
            }
        } catch { iCloud = error.localizedDescription }
    }
}
