#if DEBUG
import Foundation
import PartsKit
import SwiftData

/// Launch options for development and screenshots:
///   -demo             add a few sample parts and locations when the inventory is empty
///   -tab <name>       open a tab (parts, scan, identify, locations, projects, ask, settings)
///   -identify <path>  identify the photo at a path
@MainActor
enum DebugLaunch {
    static func apply(_ app: AppModel, _ ctx: ModelContext) {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("-demo"), (try? ctx.fetchCount(FetchDescriptor<Part>())) == 0 { demo(ctx) }
        if let t = value("-tab"), let tab = AppModel.Tab(rawValue: t) { app.tab = tab }
        if let p = value("-identify"), let d = try? Data(contentsOf: URL(fileURLWithPath: p)) { app.tab = .identify; app.photoForIdentify = d }
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
