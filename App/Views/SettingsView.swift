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
            Section("Recognition") {
                LabeledContent("Apple Intelligence", value: AppleIntelligence.status)
                LabeledContent("Recognising by look", value: LookModel.isAvailable ? "MobileCLIP, on this device" : "Not in this build")
                LabeledContent("Built-in parts list", value: "\(Catalog.shared.entries.count) parts, \(Catalog.shared.generic.count) kinds")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await checkAccount() }
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
