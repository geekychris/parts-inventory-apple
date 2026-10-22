import Foundation

/// Matching a photo to supplier listings in a batch: which numbers to look up, which listing is best, and
/// whether it's sure enough to add without asking.
public enum BatchMatch {
    /// A part number for comparing: upper case, letters and digits only ("atmega328p-pu" → "ATMEGA328PPU").
    public static func key(_ s: String) -> String { Identify.squash(s) }

    /// Companies bought by others print the old name on the part ("ATMEL" on a Microchip chip).
    static let makerAliases: [String: String] = [
        "ATMEL": "MICROCHIP", "MICREL": "MICROCHIP", "MICROSEMI": "MICROCHIP", "SST": "MICROCHIP",
        "MAXIM": "ANALOG", "LINEAR": "ANALOG", "LTC": "ANALOG", "ADI": "ANALOG",
        "FAIRCHILD": "ONSEMI", "ON": "ONSEMI", "FREESCALE": "NXP", "PHILIPS": "NXP",
        "INTERSIL": "RENESAS", "IDT": "RENESAS", "DIALOG": "RENESAS", "CYPRESS": "INFINEON", "IR": "INFINEON",
        "INTERNATIONAL": "INFINEON", "NATIONAL": "TEXAS", "BURR": "TEXAS", "TI": "TEXAS", "ST": "STMICROELECTRONICS",
    ]

    /// A manufacturer for comparing: its first word, with old company names folded into the new.
    public static func makerKey(_ s: String) -> String {
        let first = s.uppercased().split { !$0.isLetter && !$0.isNumber }.first.map(String.init) ?? ""
        return makerAliases[first] ?? first
    }

    /// The numbers to look up for a photo, best first: a bag label's part numbers, then the part numbers of
    /// the candidates (catalog, inventory, unrecognised numbers, Apple Intelligence's reading).
    public static func queries(label: BagLabel?, candidates: [Candidate], max: Int = 2) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmed
            guard key(t).count >= 3, !out.contains(where: { key($0) == key(t) }) else { return }
            out.append(t)
        }
        if let l = label, l.hasPart { add(l.mpn); add(l.spn) }
        for c in candidates {
            switch c.source {
            case .catalog(let e): add(e.mpn)
            case .inventory(let p): add(p.mpn)
            case .unknown(let t): add(t)
            case .reading(let r): add(r.mpn)
            case .generic: break
            }
        }
        return Array(out.prefix(max))
    }

    /// The part-number-like words read from a photo (single words and neighbours joined), as keys.
    public static func readKeys(_ ocrText: String) -> Set<String> {
        Set(Identify.tokens(Identify.words(ocrText)).map { key($0.text) }.filter { $0.count >= 3 })
    }

    /// How well a listing matches: 0 — its number was read on the part (or is on the bag label);
    /// 1 — it is a number that was looked up; 2 — it was read with OCR's usual confusions, or starts with a
    /// number looked up; 3 — anything else the search found.
    public static func tier(_ p: SupplierProduct, read: Set<String>, label: BagLabel?, queries: [String]) -> Int {
        let m = key(p.mpn), s = key(p.spn)
        if let l = label, l.hasPart, (!l.mpn.isEmpty && key(l.mpn) == m) || (!l.spn.isEmpty && key(l.spn) == s) { return 0 }
        if read.contains(m) { return 0 }
        let qs = queries.map(key)
        if qs.contains(m) || qs.contains(s) { return 1 }
        let canonRead = Set(read.map(Identify.canon))
        if canonRead.contains(Identify.canon(m)) || qs.contains(where: { !$0.isEmpty && m.hasPrefix($0) }) { return 2 }
        return 3
    }

    /// Listings best first: by `tier`, then the maker printed on the part, then in stock before out of stock,
    /// then as the suppliers ordered them.
    public static func rank(_ products: [SupplierProduct], ocrText: String, label: BagLabel? = nil, queries: [String]) -> [SupplierProduct] {
        let read = readKeys(ocrText), printed = printedMakers(ocrText, label: label)
        return products.enumerated().sorted { a, b in
            let ta = tier(a.element, read: read, label: label, queries: queries), tb = tier(b.element, read: read, label: label, queries: queries)
            if ta != tb { return ta < tb }
            let pa = printed.contains(makerKey(a.element.manufacturer)), pb = printed.contains(makerKey(b.element.manufacturer))
            if pa != pb { return pa }
            let sa = (a.element.stock ?? 0) > 0, sb = (b.element.stock ?? 0) > 0
            if sa != sb { return sa }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Sure enough to add without asking: the best listing's number was read on the part (or is on the label),
    /// and every listing read that exactly is the same part — one number, from one maker (old company names
    /// count as the new one; if makers differ, the maker printed on the part decides).
    public static func isSure(_ ranked: [SupplierProduct], ocrText: String, label: BagLabel? = nil, queries: [String]) -> Bool {
        let read = readKeys(ocrText)
        let exact = ranked.filter { tier($0, read: read, label: label, queries: queries) == 0 }
        guard let best = ranked.first, exact.first == best else { return false }
        guard Set(exact.map { key($0.mpn) }).count == 1 else { return false }
        let makers = Set(exact.map { makerKey($0.manufacturer) }.filter { !$0.isEmpty })
        if makers.count <= 1 { return true }
        let printed = printedMakers(ocrText, label: label)
        return makers.intersection(printed).count == 1 && printed.contains(makerKey(best.manufacturer))
    }

    /// Makers named on the part or its label, as `makerKey`s.
    static func printedMakers(_ ocrText: String, label: BagLabel?) -> Set<String> {
        var out = Set(Identify.words(ocrText).map { makerKey($0.text) }.filter { !$0.isEmpty })
        if let m = label?.manufacturer, !m.isEmpty { out.insert(makerKey(m)) }
        return out
    }

    /// The same part at the other supplier (same number and maker), in stock first.
    public static func partner(of p: SupplierProduct, in list: [SupplierProduct]) -> SupplierProduct? {
        let m = key(p.mpn), mk = makerKey(p.manufacturer)
        return list.filter { $0.supplier != p.supplier && key($0.mpn) == m && makerKey($0.manufacturer) == mk }
            .max { ($0.stock ?? -1) < ($1.stock ?? -1) }
    }
}
