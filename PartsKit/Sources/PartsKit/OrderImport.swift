import Foundation
#if canImport(Compression)
import Compression
#endif

/// A supplier order read from the file Digi-Key, Mouser or LCSC let you download from your order history
/// (CSV, Excel or the "Excel" that's really a web page), or from the order table copied off their website.
public struct SupplierOrder: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public var id: Int
        /// digikey, mouser, lcsc (or nil when it can't be told).
        public var supplier: String?
        /// The supplier's own part number (296-1395-1-ND, 595-LM358DR, C7950).
        public var spn = ""
        public var mpn = ""
        public var manufacturer = ""
        public var description = ""
        public var qty = 0
        public var unitPrice: Double?
        public var customerReference = ""

        public init(id: Int, supplier: String? = nil) { self.id = id; self.supplier = supplier }
        /// The number to show and match on: the maker's, else the supplier's.
        public var partNumber: String { mpn.isEmpty ? spn : mpn }
    }

    public var supplier: String?
    /// The sales order or web order number, when the file says.
    public var number = ""
    public var currency: String?
    public var lines: [Line] = []

    public init(supplier: String? = nil, lines: [Line] = []) { self.supplier = supplier; self.lines = lines }

    public enum ReadError: LocalizedError, Equatable {
        case notATable, noColumns(found: [String]), oldExcel
        public var errorDescription: String? {
            switch self {
            case .notATable: "This doesn't look like an order: no table was found in it."
            case .noColumns(let found):
                "No quantity and part number columns were found" + (found.isEmpty ? "." : " (the headings were: \(found.prefix(12).joined(separator: ", "))).")
            case .oldExcel: "This is an old-style Excel file (.xls). Open it and save it as CSV or .xlsx, then import that."
            }
        }
    }

    /// Read an order from a downloaded file (CSV, TSV, .xlsx, or HTML saved as .xls) or pasted text.
    public static func read(_ data: Data, fileName: String? = nil) throws -> SupplierOrder {
        let rows = try TableReader.rows(data)
        var order = try parse(rows: rows, fileName: fileName)
        if order.number.isEmpty, !data.starts(with: [0x50, 0x4B]), let text = String(data: data, encoding: .utf8) {
            order.number = orderNumber(in: TableReader.stripTags(text)) ?? ""
        }
        return order
    }

    public static func read(text: String, fileName: String? = nil) throws -> SupplierOrder {
        var order = try parse(rows: TableReader.rows(text: text), fileName: fileName)
        // An order number outside the table (a web page's heading).
        if order.number.isEmpty { order.number = orderNumber(in: TableReader.stripTags(text)) ?? "" }
        return order
    }

    // MARK: - Columns

    /// Headings, squashed to lowercase letters and digits, for each column, best first.
    static let quantityNames = ["quantityshipped", "shippedquantity", "qtyshipped", "shipqty", "shippedqty", "shipped",
                                "quantity", "qty", "orderqty", "orderquantity", "quantityordered", "orderedquantity", "qtyordered"]
    static let mpnNames = ["manufacturerpartnumber", "mfrpartnumber", "manufacturerpart", "mfrpart", "mfrno", "mfrnumber", "mfr",
                           "manufacturepartnumber", "mfgpartnumber", "mpn"]
    static let manufacturerNames = ["manufacturer", "manufacturername", "mfrname", "mfr", "mfg", "brand"]
    static let descriptionNames = ["description", "productdescription", "partdescription", "desc"]
    static let priceNames = ["unitprice", "price", "unitcost", "priceeach"]
    static let referenceNames = ["customerreference", "customerpartnumber", "customerno", "customerpart", "yourpartnumber", "reference"]
    static let supplierPNNames: [(supplier: String, names: [String])] = [
        ("digikey", ["digikeypartnumber", "digikeypart", "digikeyno", "digikeypn", "dkpartnumber", "dkpn", "digikey"]),
        ("mouser", ["mouserno", "mousernumber", "mouserpartnumber", "mouserpart", "mouserpn", "mouser"]),
        ("lcsc", ["lcscpartnumber", "lcscpart", "lcscno", "lcsc", "lcscpn"]),
    ]

    static func squash(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)) }

    /// The first column whose heading is one of `names` (exactly, or starting with it — "Price (USD)").
    static func column(_ headers: [String], _ names: [String], excluding: Set<Int> = []) -> Int? {
        for n in names { if let i = headers.indices.first(where: { !excluding.contains($0) && headers[$0] == n }) { return i } }
        for n in names where n.count >= 5 {
            if let i = headers.indices.first(where: { !excluding.contains($0) && headers[$0].hasPrefix(n) }) { return i }
        }
        return nil
    }

    struct Columns {
        var qty: Int, spn: Int?, mpn: Int?, manufacturer: Int?, description: Int?, price: Int?, reference: Int?
        var supplier: String?
    }

    static func columns(_ raw: [String], fileName: String?) -> Columns? {
        let h = raw.map(squash)
        guard let qty = column(h, quantityNames) else { return nil }
        var supplier: String?, spn: Int?
        for (s, names) in supplierPNNames { if let i = column(h, names) { supplier = s; spn = i; break } }
        let mpn = column(h, mpnNames, excluding: Set([spn].compactMap { $0 }))
        // Digi-Key's own files call their number just "Part Number", beside "Manufacturer Part Number".
        if spn == nil, let i = column(h, ["partnumber", "partno", "part"], excluding: Set([mpn].compactMap { $0 })) { spn = i }
        guard spn != nil || mpn != nil else { return nil }
        let used = Set([qty, spn, mpn].compactMap { $0 })
        return Columns(qty: qty, spn: spn, mpn: mpn,
                       manufacturer: column(h, manufacturerNames, excluding: used),
                       description: column(h, descriptionNames, excluding: used),
                       price: column(h, priceNames, excluding: used.union(h.indices.filter { h[$0].hasPrefix("ext") || h[$0].contains("total") })),
                       reference: column(h, referenceNames, excluding: used),
                       supplier: supplier ?? supplierNamed(in: (fileName ?? "") + " " + raw.joined(separator: " ")))
    }

    static func supplierNamed(in s: String) -> String? {
        let t = squash(s)
        if t.contains("digikey") { return "digikey" }
        if t.contains("mouser") { return "mouser" }
        if t.contains("lcsc") { return "lcsc" }
        return nil
    }

    /// Which supplier a part number of theirs looks like it's from.
    public static func supplierFromNumber(_ spn: String) -> String? {
        let s = spn.uppercased()
        if s.hasSuffix("-ND") || s.hasSuffix("-1-ND") || s.contains("-ND ") { return "digikey" }
        if s.range(of: #"^C\d{3,9}$"#, options: .regularExpression) != nil { return "lcsc" }
        if s.range(of: #"^\d{2,4}-[A-Z0-9]"#, options: .regularExpression) != nil { return "mouser" }
        return nil
    }

    // MARK: - Rows

    static func parse(rows: [[String]], fileName: String?) throws -> SupplierOrder {
        let rows = rows.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }.filter { $0.contains { !$0.isEmpty } }
        guard !rows.isEmpty else { throw ReadError.notATable }
        guard let headerIndex = rows.prefix(60).firstIndex(where: { columns($0, fileName: fileName) != nil }),
              let cols = columns(rows[headerIndex], fileName: fileName) else {
            throw ReadError.noColumns(found: rows.first ?? [])
        }
        var order = SupplierOrder(supplier: cols.supplier)
        // Above the table, or the file's name: "Sales Order 87654321", "Web Order #: 123…".
        let before = rows[..<headerIndex].map { $0.joined(separator: " ") }.joined(separator: " ")
        order.number = orderNumber(in: before) ?? orderNumber(in: fileName ?? "") ?? ""
        let priceHeader = cols.price.map { rows[headerIndex][$0] } ?? ""
        order.currency = currency(in: priceHeader + " " + rows[(headerIndex + 1)...].prefix(3).compactMap { r in cols.price.flatMap { $0 < r.count ? r[$0] : nil } }.joined(separator: " "))

        func cell(_ r: [String], _ i: Int?) -> String { i.flatMap { $0 < r.count ? r[$0] : nil } ?? "" }
        for r in rows[(headerIndex + 1)...] {
            let first = r.first { !$0.isEmpty }?.lowercased() ?? ""
            if ["total", "subtotal", "sub total", "merchandise total", "shipping", "tax"].contains(where: { first.hasPrefix($0) }) { continue }
            guard let q = number(cell(r, cols.qty)).map({ Int($0.rounded()) }), q > 0 else { continue }
            var l = Line(id: order.lines.count, supplier: cols.supplier)
            l.spn = cell(r, cols.spn); l.mpn = cell(r, cols.mpn)
            guard !l.spn.isEmpty || !l.mpn.isEmpty else { continue }
            if l.spn.caseInsensitiveCompare(l.mpn) == .orderedSame { l.spn = "" }
            l.qty = q
            l.manufacturer = cell(r, cols.manufacturer)
            l.description = cell(r, cols.description)
            l.unitPrice = number(cell(r, cols.price))
            l.customerReference = cell(r, cols.reference)
            if l.supplier == nil, !l.spn.isEmpty { l.supplier = supplierFromNumber(l.spn) }
            order.lines.append(l)
        }
        if order.supplier == nil {
            let found = Set(order.lines.compactMap(\.supplier))
            if found.count == 1 { order.supplier = found.first }
        }
        if order.lines.isEmpty { throw ReadError.noColumns(found: rows[headerIndex]) }
        return order
    }

    static func orderNumber(in s: String) -> String? {
        guard let r = s.range(of: #"(?i)(sales\s*order|web\s*order|order)[\s_-]*(no\.?|number|#)?[\s:#_-]*([A-Z]{0,3}\d{5,12})"#, options: .regularExpression) else { return nil }
        return String(s[r]).components(separatedBy: CharacterSet.decimalDigits.union(.uppercaseLetters).inverted).last { $0.contains { $0.isNumber } }
    }

    static func currency(in s: String) -> String? {
        for (mark, code) in [("USD", "USD"), ("EUR", "EUR"), ("GBP", "GBP"), ("CAD", "CAD"), ("AUD", "AUD"), ("€", "EUR"), ("£", "GBP"), ("$", "USD")]
            where s.contains(mark) { return code }
        return nil
    }

    /// "$1,234.50", "0,42 €", "1 000" → a number.
    static func number(_ s: String) -> Double? {
        var t = s.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        guard !t.isEmpty else { return nil }
        if t.contains(","), !t.contains(".") {
            // "0,42" is a decimal comma; "1,000" is thousands.
            let after = t.split(separator: ",").last ?? ""
            t = after.count == 3 && t.split(separator: ",").count > 1 && !t.hasPrefix("0,") ? t.replacingOccurrences(of: ",", with: "") : t.replacingOccurrences(of: ",", with: ".")
        } else {
            t = t.replacingOccurrences(of: ",", with: "")
        }
        return Double(t)
    }
}

/// Rows of cells from CSV, TSV, an .xlsx workbook's first sheet, or an HTML table.
public enum TableReader {
    public static func rows(_ data: Data) throws -> [[String]] {
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return try xlsx(data) }
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { throw SupplierOrder.ReadError.oldExcel }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) else {
            throw SupplierOrder.ReadError.notATable
        }
        return rows(text: text)
    }

    public static func rows(text: String) -> [[String]] {
        let t = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        if t.range(of: "<table", options: .caseInsensitive) != nil { return html(t) }
        let sample = t.split(separator: "\n").prefix(20).joined(separator: "\n")
        let tabs = sample.filter { $0 == "\t" }.count, commas = sample.filter { $0 == "," }.count, semis = sample.filter { $0 == ";" }.count
        let sep: Character = tabs > 0 && tabs >= commas / 2 ? "\t" : (semis > commas ? ";" : ",")
        return delimited(t, separator: sep)
    }

    /// RFC 4180: quoted fields may hold the separator, newlines and doubled quotes.
    public static func delimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(text).makeIterator()
        var pending: Character?
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""; rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func html(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var trs = text
        for tag in ["tr", "td", "th"] {
            trs = trs.replacingOccurrences(of: "<" + tag, with: "<" + tag, options: .caseInsensitive)
                .replacingOccurrences(of: "</" + tag, with: "</" + tag, options: .caseInsensitive)
        }
        for tr in trs.components(separatedBy: "<tr").dropFirst() {
            let body = tr.components(separatedBy: "</tr").first ?? tr
            var cells: [String] = []
            for part in body.components(separatedBy: "<t").dropFirst() where part.hasPrefix("d") || part.hasPrefix("h") {
                guard let start = part.firstIndex(of: ">") else { continue }
                var inner = String(part[part.index(after: start)...])
                if let end = inner.range(of: "</t") { inner = String(inner[..<end.lowerBound]) }
                cells.append(decode(stripTags(inner)))
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        return rows
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func decode(_ s: String) -> String {
        var t = s
        for (e, c) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            t = t.replacingOccurrences(of: e, with: c)
        }
        t = t.replacingOccurrences(of: #"&#(\d+);"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: .xlsx

    /// The first worksheet of an .xlsx file as rows of text.
    static func xlsx(_ data: Data) throws -> [[String]] {
        let files = try ZipReader.entries(data)
        let shared = files["xl/sharedStrings.xml"].map { sharedStrings(String(decoding: $0, as: UTF8.self)) } ?? []
        let sheetName = files.keys.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first
        guard let name = sheetName, let sheet = files[name] else { throw SupplierOrder.ReadError.notATable }
        return worksheet(String(decoding: sheet, as: UTF8.self), shared: shared)
    }

    static func sharedStrings(_ xml: String) -> [String] {
        xml.components(separatedBy: "<si").dropFirst().map { si in
            let body = si.components(separatedBy: "</si>").first ?? si
            // Every <t> run in the item (rich text has several).
            return body.components(separatedBy: "<t").dropFirst().compactMap { t -> String? in
                guard t.hasPrefix(">") || t.hasPrefix(" ") else { return nil }
                guard let start = t.firstIndex(of: ">") else { return nil }
                let inner = t[t.index(after: start)...]
                return decode(String(inner.components(separatedBy: "</t>").first ?? ""))
            }.joined()
        }
    }

    static func worksheet(_ xml: String, shared: [String]) -> [[String]] {
        var rows: [[String]] = []
        for rowXML in xml.components(separatedBy: "<row").dropFirst() {
            let body = rowXML.components(separatedBy: "</row>").first ?? rowXML
            var cells: [String] = []
            for c in body.components(separatedBy: "<c ").dropFirst() {
                let head = c.prefix { $0 != ">" }
                let ref = attribute("r", in: String(head)) ?? ""
                let col = columnIndex(ref) ?? cells.count
                let type = attribute("t", in: String(head))
                var value = ""
                if type == "inlineStr", let r = c.range(of: "<t") {
                    let rest = c[r.upperBound...]
                    if let s = rest.firstIndex(of: ">") { value = decode(String(rest[rest.index(after: s)...].components(separatedBy: "</t>").first ?? "")) }
                } else if let r = c.range(of: "<v>"), let e = c.range(of: "</v>") {
                    let v = String(c[r.upperBound..<e.lowerBound])
                    value = type == "s" ? (Int(v).flatMap { $0 < shared.count ? shared[$0] : nil } ?? "") : decode(v)
                }
                while cells.count < col { cells.append("") }
                cells.append(value)
            }
            rows.append(cells)
        }
        return rows
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: " \(name)=\"") ?? (tag.hasPrefix("\(name)=\"") ? tag.range(of: "\(name)=\"") : nil) else { return nil }
        return String(tag[r.upperBound...].prefix { $0 != "\"" })
    }

    /// "C12" → 2.
    static func columnIndex(_ ref: String) -> Int? {
        let letters = ref.prefix { $0.isLetter }.uppercased()
        guard !letters.isEmpty else { return nil }
        return letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }
}

/// Reads the files in a zip archive (stored or deflated), as .xlsx workbooks are.
enum ZipReader {
    struct Bad: Error {}

    static func entries(_ data: Data) throws -> [String: Data] {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        // The end-of-central-directory record, searched for from the end.
        guard b.count > 22, let eocd = stride(from: b.count - 22, through: max(0, b.count - 65_557), by: -1).first(where: { u32($0) == 0x0605_4B50 }) else { throw Bad() }
        var p = u32(eocd + 16)
        var out: [String: Data] = [:]
        for _ in 0..<u16(eocd + 10) {
            guard u32(p) == 0x0201_4B50 else { throw Bad() }
            let method = u16(p + 10), compressed = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            guard u32(local) == 0x0403_4B50 else { throw Bad() }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= b.count else { throw Bad() }
            let raw = Data(b[start..<(start + compressed)])
            switch method {
            case 0: out[name] = raw
            case 8: out[name] = try inflate(raw, size: size)
            default: continue
            }
        }
        return out
    }

    static func inflate(_ raw: Data, size: Int) throws -> Data {
        #if canImport(Compression)
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw Bad() }
        return out
        #else
        throw Bad()
        #endif
    }
}
