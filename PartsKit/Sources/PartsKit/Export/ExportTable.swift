import Foundation

/// A table to export: a header and rows of cells, shared by the CSV and Excel writers.
public struct ExportTable: Sendable, Equatable {
    public enum Cell: Sendable, Equatable {
        case text(String), number(Double)
        public static let empty = Cell.text("")
        /// The cell as CSV has it.
        public var string: String { switch self { case .text(let s): s; case .number(let n): Values.plain(n) } }
    }
    public var header: [String]
    public var rows: [[Cell]]
    /// Column widths in characters, for Excel.
    public var widths: [Double]

    public init(header: [String], rows: [[Cell]], widths: [Double]? = nil) {
        self.header = header; self.rows = rows
        self.widths = widths ?? header.indices.map { i in
            // As wide as the longest value, within reason.
            let longest = rows.reduce(header[i].count) { max($0, i < $1.count ? $1[i].string.count : 0) }
            return Double(min(max(longest + 2, 6), 60))
        }
    }
}

extension InventoryRow {
    /// The export columns: MPN, Manufacturer, Description, Category, Value, Package, Qty, Low stock, Location,
    /// Datasheet, Supplier part numbers, Tags, Notes, Updated (an ISO date), and Source first when any row has one.
    public static func table(_ rows: [InventoryRow]) -> ExportTable {
        let withSource = rows.contains { !$0.source.isEmpty }
        var header = ["MPN", "Manufacturer", "Description", "Category", "Value", "Package", "Qty", "Low stock", "Location",
                      "Datasheet", "Supplier part numbers", "Tags", "Notes", "Updated"]
        if withSource { header.insert("Source", at: 0) }
        let cells: [[ExportTable.Cell]] = rows.map { r in
            var c: [ExportTable.Cell] = [
                .text(r.mpn), .text(r.manufacturer), .text(r.description), .text(r.categoryPath.joined(separator: " / ")),
                .text(r.value), .text(r.package), .number(Double(r.qty)), r.lowStock.map { .number(Double($0)) } ?? .empty,
                .text(r.location), .text(r.datasheet), .text(r.supplierNumbers), .text(r.tags.joined(separator: ", ")),
                .text(r.notes), .text(r.updated.timeIntervalSince1970 > 0 ? Export.isoDate(r.updated) : ""),
            ]
            if withSource { c.insert(.text(r.source), at: 0) }
            return c
        }
        return ExportTable(header: header, rows: cells)
    }

    /// By category, then MPN: the order of the repository's inventory.json and parts.csv.
    public static func catalogueOrder(_ rows: [InventoryRow]) -> [InventoryRow] {
        rows.sorted { x, y in
            x.category != y.category ? Export.less(x.category, y.category) : x.mpn != y.mpn ? Export.less(x.mpn, y.mpn) : x.id < y.id
        }
    }

    /// "Digi-Key: 296-1395-1-ND; Mouser: 595-LM358DR".
    public var supplierNumbers: String {
        suppliers.map { "\(Export.supplierName($0.supplier)): \($0.pn)" }.joined(separator: "; ")
    }
}

/// Helpers shared by the exports. Locale-independent, so the same inventory gives the same files anywhere.
public enum Export {
    /// "2026-10-22", in UTC.
    public static func isoDate(_ d: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "Digi-Key" for "digikey"; an unknown supplier as stored.
    public static func supplierName(_ id: String) -> String { Supplier.named(id)?.name ?? id }

    /// A supplier's page for a part number: its stored URL, or a search.
    public static func supplierURL(_ s: SupplierEntry) -> String {
        if !s.url.isEmpty { return s.url }
        return Supplier.named(s.supplier)?.search(s.pn)?.absoluteString ?? ""
    }

    /// "1,430", whatever the locale.
    public static func count(_ n: Int) -> String {
        let s = String(abs(n))
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0, (s.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    /// Orders strings the same way everywhere: case-insensitive with numbers by value, then exactly.
    public static func less(_ a: String, _ b: String) -> Bool {
        switch a.compare(b, options: [.caseInsensitive, .numeric]) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a < b
        }
    }
}
