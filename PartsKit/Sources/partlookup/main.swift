import Foundation
import PartsKit

// Looks part numbers up at Digi-Key and Mouser with the keys in the environment:
//   DIGIKEY_CLIENT_ID, DIGIKEY_CLIENT_SECRET, MOUSER_API_KEY
// Usage: swift run partlookup LM358DR [more part numbers…]

let env = ProcessInfo.processInfo.environment
let queries = Array(CommandLine.arguments.dropFirst())
guard !queries.isEmpty else {
    print("usage: partlookup <part number>…  (keys from DIGIKEY_CLIENT_ID, DIGIKEY_CLIENT_SECRET, MOUSER_API_KEY)")
    exit(2)
}
let lookup = SupplierLookup(digikeyID: env["DIGIKEY_CLIENT_ID"] ?? "", digikeySecret: env["DIGIKEY_CLIENT_SECRET"] ?? "",
                            mouserKey: env["MOUSER_API_KEY"] ?? "")
print("Digi-Key: \(lookup.digikey == nil ? "no keys" : "keys set")   Mouser: \(lookup.mouser == nil ? "no key" : "key set")")
guard lookup.isConfigured else { exit(1) }

func cell(_ s: String, _ w: Int) -> String { s.count > w ? String(s.prefix(w - 1)) + "…" : s.padding(toLength: w, withPad: " ", startingAt: 0) }
func price(_ p: SupplierProduct, _ q: Int) -> String { p.unitPrice(for: q).map { String(format: "%.4g", $0.unit) } ?? "-" }

var failed = false
for q in queries {
    let r = await lookup.lookup(q)
    print("\n== \(q): \(r.products.count) result\(r.products.count == 1 ? "" : "s")")
    for (id, e) in r.errors.sorted(by: { $0.key < $1.key }) { print("  ! \(Supplier.named(id)?.name ?? id): \(e)"); failed = true }
    for s in ["digikey", "mouser"] {
        let rows = r.products.filter { $0.supplier == s }
        guard !rows.isEmpty else { continue }
        print("  \(Supplier.named(s)?.name ?? s)")
        print("    " + [cell("MPN", 18), cell("Maker", 18), cell("Supplier PN", 22), cell("Stock", 9), cell("@1", 8), cell("@10", 8), cell("@100", 8), "Datasheet"].joined(separator: " "))
        for p in rows.prefix(8) {
            print("    " + [cell(p.mpn, 18), cell(p.manufacturer, 18), cell(p.spn, 22), cell(p.stock.map(String.init) ?? "-", 9),
                          cell(price(p, 1), 8), cell(price(p, 10), 8), cell(price(p, 100), 8), p.datasheet].joined(separator: " "))
        }
    }
}
exit(failed ? 1 : 0)
