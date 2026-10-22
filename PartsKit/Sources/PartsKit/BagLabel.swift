import Foundation

/// What a distributor bag label says: an ECIA format-06 Data Matrix (Digi-Key, Mouser and others),
/// an LCSC QR code, or a 1-D barcode with a part number or a quantity.
public struct BagLabel: Equatable, Sendable {
    public enum Kind: String, Sendable { case ecia, lcsc, plain }
    public struct Field: Equatable, Sendable { public var di, name, value: String }

    public var kind: Kind = .plain
    /// digikey, mouser, lcsc (or nil).
    public var supplier: String?
    /// The supplier's part number.
    public var spn = ""
    public var mpn = ""
    public var customerPn = ""
    public var qty: Int?
    public var lot = ""
    public var dateCode = ""
    public var po = ""
    public var salesOrder = ""
    public var invoice = ""
    public var countryOfOrigin = ""
    public var manufacturer = ""
    public var fields: [Field] = []
    public var raw = ""
    /// The supplier was guessed from the shape of the number.
    public var maybe = false

    /// Anything worth adding to the inventory.
    public var hasPart: Bool { !spn.isEmpty || !mpn.isEmpty }
}

public enum BagLabels {
    static let GS = "\u{1d}", RS = "\u{1e}", EOT = "\u{04}"

    /// ANSI MH10.8.2 data identifiers seen on bag labels (ECIA EIGP 114).
    static let names: [String: String] = [
        "K": "Customer PO", "1K": "Supplier order number", "10K": "Invoice number", "11K": "Packing list number", "4K": "PO line", "14K": "PO line",
        "P": "Customer part number", "1P": "Manufacturer part number", "30P": "Supplier part number", "Q": "Quantity",
        "1T": "Lot code", "9D": "Date code (YYWW)", "10D": "Date code (YYWW)", "6D": "Ship date (YYYYMMDD)", "4L": "Country of origin",
        "1V": "Manufacturer", "11Z": "Pick", "12Z": "Part ID", "13Z": "Load ID", "20Z": "Padding", "3S": "Package ID", "5D": "Date (YYMMDD)", "16D": "Date (YYYYMMDD)",
    ]

    /// Bring a scanned string back to real control characters: keyboard-wedge scanners and copy and
    /// paste turn GS/RS/EOT into ␝ ␞ ␄, {GS}, <GS>, ^] or ~d029.
    public static func normalise(_ raw: String) -> String {
        var s = raw
        s = RE("␝|\\{GS\\}|<GS>|\\[GS\\]|\\\\x1d|\\\\u001d|~d029|\\^\\]|<0x1D>", .caseInsensitive).replace(s, GS)
        s = RE("␞|\\{RS\\}|<RS>|\\[RS\\]|\\\\x1e|\\\\u001e|~d030|\\^\\^|<0x1E>", .caseInsensitive).replace(s, RS)
        s = RE("␄|\\{EOT\\}|<EOT>|\\[EOT\\]|\\\\x04|\\\\u0004|~d004|<0x04>", .caseInsensitive).replace(s, EOT)
        return RE("^\\s+|[\\r\\n]+$").replace(s, "")
    }

    static func splitECIA(_ raw: String) -> (format: String, fields: [(di: String, value: String)])? {
        var s = normalise(raw)
        guard let start = s.range(of: "[)>") else { return nil }
        s = String(s[start.upperBound...])
        if s.hasPrefix(RS) { s.removeFirst() }
        let fmt = String(s.prefix(2))
        guard RE("^\\d\\d$").test(fmt) else { return nil }
        s = String(s.dropFirst(2))
        if let end = RE("\(RS)\(EOT)|\(RS)$|\(EOT)").search(s) { s = (s as NSString).substring(to: end) }
        var fields: [(String, String)] = []
        for part in s.components(separatedBy: GS) where !part.isEmpty {
            if let m = RE("^(\\d{0,3}[A-Z])([\\s\\S]*)$").match(part) { fields.append((m[1]!, m[2] ?? "")) } else { fields.append(("?", part)) }
        }
        return (fmt, fields)
    }

    public static func parse(_ raw: String) -> BagLabel {
        var r = BagLabel(raw: raw)
        if let e = splitECIA(raw) {
            r.kind = .ecia
            var f: [String: String] = [:]
            for (di, value) in e.fields {
                r.fields.append(.init(di: di, name: names[di] ?? (di == "?" ? "Unrecognised" : "Field " + di), value: value))
                if f[di] == nil { f[di] = value }
            }
            let P = f["P"] ?? ""
            let endsND = RE("-ND$", .caseInsensitive).test(P)
            let isDK = f["30P"] != nil || endsND || f["11Z"] != nil || f["12Z"] != nil || f["13Z"] != nil
            let isMouser = !isDK && (f["1V"] != nil || f["14K"] != nil)
            r.supplier = isDK ? "digikey" : isMouser ? "mouser" : nil
            r.mpn = (f["1P"] ?? "").trimmed
            if isDK {
                r.spn = (f["30P"] ?? (endsND ? P : "")).trimmed
                if !P.isEmpty && !endsND && P != r.spn { r.customerPn = P.trimmed }
            } else {
                r.customerPn = P.trimmed
            }
            r.salesOrder = (f["1K"] ?? "").trimmed
            r.po = (f["K"] ?? "").trimmed
            r.invoice = (f["10K"] ?? f["11K"] ?? "").trimmed
            if let q = f["Q"]?.trimmed, RE("^\\d+$").test(q) { r.qty = Int(q) }
            r.lot = (f["1T"] ?? "").trimmed
            r.dateCode = (f["10D"] ?? f["9D"] ?? "").trimmed
            r.countryOfOrigin = (f["4L"] ?? "").trimmed
            r.manufacturer = (f["1V"] ?? "").trimmed
            return r
        }
        if let l = parseLCSC(raw) { return l }
        let s = RE("[\\x00-\\x1f]").replace(normalise(raw).trimmed, "")
        r.raw = s
        if RE("^\\d+$").test(s) && s.count <= 6 { r.qty = Int(s); return r }
        if RE("-ND$", .caseInsensitive).test(s) { r.supplier = "digikey"; r.spn = s }
        else if RE("^C\\d{3,9}$", .caseInsensitive).test(s) { r.supplier = "lcsc"; r.spn = s.uppercased() }
        else if RE("^\\d{2,3}-[A-Z0-9]", .caseInsensitive).test(s) && s.count > 5 { r.supplier = "mouser"; r.spn = s; r.maybe = true }
        else { r.mpn = s }
        return r
    }

    /// LCSC reel and bag QR codes: {pbn:PICK…,on:SO…,pc:C25804,pm:0603WAF1002T5E,qty:100,…}
    static func parseLCSC(_ raw: String) -> BagLabel? {
        let s = raw.trimmed
        guard RE("^\\{.*\\bpc:\\s*C\\d+", .caseInsensitive).test(s) else { return nil }
        let fieldNames = ["pbn": "Pick batch", "on": "Order number", "pc": "LCSC part number", "pm": "Manufacturer part number", "qty": "Quantity",
                          "mc": "Manufacturer code", "cc": "Carton count", "pdi": "Product ID", "hp": "Hazard/packaging", "wc": "Warehouse"]
        var o: [(String, String)] = []
        for kv in RE("^\\{|\\}$").replace(s, "").components(separatedBy: ",") {
            guard let i = kv.firstIndex(of: ":"), i != kv.startIndex else { continue }
            o.append((String(kv[..<i]).trimmed, String(kv[kv.index(after: i)...]).trimmed))
        }
        let d = Dictionary(o, uniquingKeysWith: { a, _ in a })
        var r = BagLabel(kind: .lcsc, supplier: "lcsc", raw: raw)
        r.spn = (d["pc"] ?? "").uppercased()
        r.mpn = d["pm"] ?? ""
        if let q = d["qty"], RE("^\\d+$").test(q) { r.qty = Int(q) }
        r.salesOrder = d["on"] ?? ""
        r.lot = d["pbn"] ?? ""
        r.fields = o.map { .init(di: $0.0, name: fieldNames[$0.0] ?? $0.0, value: $0.1) }
        return r
    }
}

public struct Supplier: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var search: @Sendable (String) -> URL?

    public static let all: [Supplier] = [
        .init(id: "digikey", name: "Digi-Key") { URL(string: "https://www.digikey.com/en/products/result?keywords=\(q($0))") },
        .init(id: "mouser", name: "Mouser") { URL(string: "https://www.mouser.com/c/?q=\(q($0))") },
        .init(id: "lcsc", name: "LCSC") { URL(string: "https://www.lcsc.com/search?q=\(q($0))") },
        .init(id: "farnell", name: "Farnell / Newark") { URL(string: "https://www.farnell.com/search?st=\(q($0))") },
        .init(id: "other", name: "Other") { _ in nil },
    ]
    public static func named(_ id: String) -> Supplier? { all.first { $0.id == id } }
    static func q(_ s: String) -> String { s.trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
}
