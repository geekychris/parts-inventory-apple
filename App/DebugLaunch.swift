#if DEBUG
import Foundation
import PartsKit
import SwiftData
#if os(macOS)
import AppKit
#endif

/// Launch options for development and screenshots:
///   -demo             add a few sample parts and locations when the inventory is empty
///   -tab <name>       open a tab (parts, table, scan, identify, locations, projects, ask, settings)
///   -identify <path>  identify the photo at a path
///   -batch <dir>      open Batch and queue every photo in a folder
///   -apiServer, -apiToken <t>, -apiPort <n>  start the API and MCP server for this run (read by APIService)
///   -friend "Sam=<address or /folder>"  a friend's inventory for this run only (with -memoryStore)
///   -importFrom <dir>  merge a repository folder's inventory.json (as Import from folder… does)
///   -exportTo <dir>   write the repository (with the options in Settings) to <dir>/repo, and parts.csv and parts.xlsx to <dir>
///   -locationPhoto "Cabinet A=<path>"  set a location's photo (the location is made if it's missing)
///   -importOrder <path>  open Import Supplier Order with that file
///   -showPart <part number>  open a part in Parts
///   -windowFrame "x,y,w,h"  place the Mac window (from the top left of the main screen), for screenshots
///   -supplierKeysFromEnv  save DIGIKEY_CLIENT_ID, DIGIKEY_CLIENT_SECRET and MOUSER_API_KEY from the environment
///                     as the supplier keys (so they needn't be typed into Settings)
@MainActor
enum DebugLaunch {
    static func apply(_ app: AppModel, _ ctx: ModelContext) {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("-demo"), (try? ctx.fetchCount(FetchDescriptor<Part>())) == 0 { demo(ctx) }
        for (i, a) in args.enumerated() where a == "-friend" && i + 1 < args.count { FriendsStore.shared.addForDebug(args[i + 1]) }
        for (i, a) in args.enumerated() where a == "-locationPhoto" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, let d = try? Data(contentsOf: URL(fileURLWithPath: parts[1])), let jpeg = Images.jpeg(d),
               let l = Inventory.ensureLocation(parts[0], in: ctx) { l.setPhoto(jpeg) }
        }
        #if os(macOS)
        if let f = value("-windowFrame") {
            let n = f.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if n.count == 4 {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let screen = w.screen ?? NSScreen.main else { return }
                    w.setFrame(NSRect(x: n[0], y: screen.frame.maxY - n[1] - n[3], width: n[2], height: n[3]), display: true)
                }
            }
        }
        #endif
        if let p = value("-importOrder"), let d = try? Data(contentsOf: URL(fileURLWithPath: p)) {
            app.orderToImport = (d, URL(fileURLWithPath: p).lastPathComponent)
            Task { try? await Task.sleep(for: .seconds(4)); app.importingOrder = true }  // once the window is up
        }
        if let mpn = value("-showPart") {
            try? ctx.save()  // so the list's ids are the saved ones
            let uid = ((try? ctx.fetch(FetchDescriptor<Part>())) ?? []).first { $0.mpn == mpn }?.uid
            Task { try? await Task.sleep(for: .milliseconds(800)); app.partToShow = uid }
        }
        if let t = value("-tab"), let tab = AppModel.Tab(rawValue: t) { app.tab = tab }
        if args.contains("-supplierKeysFromEnv") {
            let env = ProcessInfo.processInfo.environment, keys = SupplierKeys.shared
            keys.save(digikeyID: env["DIGIKEY_CLIENT_ID"] ?? keys.digikeyID, digikeySecret: env["DIGIKEY_CLIENT_SECRET"] ?? keys.digikeySecret,
                      mouserKey: env["MOUSER_API_KEY"] ?? keys.mouserKey)
        }
        if let dir = value("-batch") {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            app.tab = .batch
            app.photosForBatch = urls.filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { try? Data(contentsOf: $0) }
        }
        if let p = value("-identify"), let d = try? Data(contentsOf: URL(fileURLWithPath: p)) { app.tab = .identify; app.photoForIdentify = d }
    }

    /// -importFrom and -exportTo, run at launch whether or not a window opens.
    static func exports(_ ctx: ModelContext) async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard value("-importFrom") != nil || value("-exportTo") != nil else { return }
        if args.contains("-demo"), (try? ctx.fetchCount(FetchDescriptor<Part>())) == 0 { demo(ctx) }
        let c = ExportController()
        c.ctx = ctx
        if let dir = value("-importFrom") { print(c.importRepository(from: URL(fileURLWithPath: dir))) }
        if let dir = value("-exportTo").map({ URL(fileURLWithPath: $0) }) {
            let table = InventoryRow.table(InventoryRow.catalogueOrder(Inventory.backup(in: ctx, photos: false).rows(defaultLowStock: ExportController.defaultLowStock)))
            try? CSV.data(table).write(to: dir.appending(path: "parts.csv"))
            try? XLSX.data(table).write(to: dir.appending(path: "parts.xlsx"))
            print(await c.writeRepository(to: dir.appending(path: "repo")))
        }
        fflush(stdout)
    }

    static func demo(_ ctx: ModelContext) {
        let drawer = Inventory.ensureLocation("Cabinet A / Drawer 1", in: ctx)
        let bin = Inventory.ensureLocation("Cabinet A / Drawer 2 / Bin 3", in: ctx)
        let boards = Inventory.ensureLocation("Shelf / Dev boards", in: ctx)
        let items: [(String, String, String, String, Int, StorageLocation?)] = [
            ("RC0603FR-0710KL", "Yageo", "RES 10K OHM 1% 1/10W 0603", "Passives/Resistors", 480, drawer),
            ("CL10B104KB8NNNC", "Samsung", "CAP CER 0.1UF 50V X7R 0603", "Passives/Capacitors/Ceramic", 950, drawer),
            ("LM358DR", "Texas Instruments", "IC OPAMP GP 2 CIRCUIT 8SOIC", "ICs/Analog", 4, bin),
            ("AMS1117-3.3", "Advanced Monolithic Systems", "IC REG LINEAR 3.3V 1A SOT223", "ICs/Power", 12, bin),
            ("ATmega328P-PU", "Microchip", "8-bit AVR microcontroller, DIP-28", "ICs/Microcontrollers", 3, bin),
            ("ESP32-DevKitC", "Espressif", "ESP32 development board", "Boards", 2, boards),
        ]
        for (mpn, mfr, desc, cat, qty, loc) in items {
            let p = Part()
            p.mpn = mpn; p.manufacturer = mfr; p.partDescription = desc; p.category = cat; p.location = loc
            p.params = Values.params(from: desc); p.package = p.params.pkg ?? ""
            if mpn == "LM358DR" { p.lowStock = 5; p.suppliers = [SupplierEntry(supplier: "digikey", pn: "296-1395-1-ND")] }
            ctx.insert(p)
            Inventory.adjust(p, by: qty, reason: "Sample data", in: ctx)
        }
    }
}
#endif
