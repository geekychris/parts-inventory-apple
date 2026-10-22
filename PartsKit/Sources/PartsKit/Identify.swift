import Foundation

/// A word read from a photo (Vision gives a confidence 0–1; stored here as 0–100 like the web tool).
public struct OCRWord: Sendable, Equatable {
    public var text: String
    public var conf: Double
    /// Words with the same line are joined in pairs and triples, because OCR splits markings.
    public var line: Int
    public init(text: String, conf: Double = 100, line: Int = 0) { self.text = text; self.conf = conf; self.line = line }
}

public struct Token: Sendable, Equatable, Hashable {
    public var text: String
    public var conf: Double
    public var joined: Bool
}

/// A part already in the inventory, as far as matching needs it.
public struct InventoryRef: Sendable, Hashable {
    public var id: String
    public var mpn: String
    public var supplierPNs: [String]
    public init(id: String, mpn: String, supplierPNs: [String] = []) { self.id = id; self.mpn = mpn; self.supplierPNs = supplierPNs }
}

/// A look score from the image model: a catalog entry or generic kind id, and a share (0–1).
public struct LookScore: Sendable, Equatable {
    public var ref: String
    public var score: Double
    public init(ref: String, score: Double) { self.ref = ref; self.score = score }
}

/// One answer to "what is this?".
public struct Candidate: Sendable, Identifiable, Equatable {
    public enum Source: Sendable, Equatable {
        case catalog(CatalogEntry)
        case inventory(InventoryRef)
        case generic(GenericKind)
        /// A part-number-looking word that matches nothing known.
        case unknown(String)
        /// A reading of the markings by Apple Intelligence.
        case reading(PartReading)
    }
    public var id: String
    public var source: Source
    public var score: Double
    public var byLook = false
    public var reasons: [String]

    public init(id: String, source: Source, score: Double, byLook: Bool = false, reasons: [String]) {
        self.id = id; self.source = source; self.score = score; self.byLook = byLook; self.reasons = reasons
    }

    public var confidence: String { Identify.confidence(score) }
}

/// What Apple Intelligence (or anything else) made of the markings: the fields of a new part.
public struct PartReading: Sendable, Equatable, Hashable {
    public var mpn: String
    public var manufacturer: String
    public var description: String
    public var category: String
    public var package: String
    public init(mpn: String = "", manufacturer: String = "", description: String = "", category: String = "", package: String = "") {
        self.mpn = mpn; self.manufacturer = manufacturer; self.description = description; self.category = category; self.package = package
    }
}

/// The fields of a new part, from a candidate.
public struct PartDraft: Sendable, Equatable {
    public var mpn = ""
    public var manufacturer = ""
    public var description = ""
    public var category = ""
    public var package = ""
    public var datasheet = ""
    public var params = PartParams()
    public var tags: [String] = []
    public var notes = ""
    public var suppliers: [SupplierEntry] = []
    public var qty = 1
    public init() {}

    /// Fill the empty fields from a supplier's listing, and keep its part number and prices.
    public mutating func fill(from p: SupplierProduct) {
        if mpn.isEmpty { mpn = p.mpn }
        if manufacturer.isEmpty { manufacturer = p.manufacturer }
        if description.isEmpty { description = p.description.isEmpty ? p.detail : p.description }
        if category.isEmpty { category = p.category }
        if package.isEmpty { package = p.normalisedPackage }
        if datasheet.isEmpty { datasheet = p.datasheet }
        if Values.summary(params).isEmpty { params = p.params(kind: params.kind) }
        let e = p.supplierEntry()
        suppliers.removeAll { $0.supplier == e.supplier && $0.pn == e.pn }
        suppliers.append(e)
    }
}

public enum Identify {
    // ------------------------------------------------------------ text normalisation
    public static func normTok(_ s: String) -> String {
        RE("^[-./+]+|[-./+]+$").replace(RE("[^A-Z0-9\\-./+]").replace(s.trimmed.uppercased(), ""), "")
    }
    public static func squash(_ s: String) -> String { RE("[^A-Z0-9]").replace(s.trimmed.uppercased(), "") }
    static let confuse: [Character: Character] = ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "S": "5", "B": "8", "Z": "2", "G": "6"]
    /// squash() with characters OCR confuses on laser-etched markings folded together.
    public static func canon(_ s: String) -> String { String(squash(s).map { confuse[$0] ?? $0 }) }

    static func lev(_ a: String, _ b: String, max: Int = 3) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > max { return max + 1 }
        var prev = Array(0...b.count)
        for i in 1...Swift.max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            var best = i
            for j in stride(from: 1, through: b.count, by: 1) {
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                best = Swift.min(best, cur[j])
            }
            if best > max { return max + 1 }
            prev = cur
        }
        return prev[b.count]
    }

    // ------------------------------------------------------------ tokens
    /// OCR words → tokens; adjacent words on a line are also joined in pairs and triples
    /// ("ATMEGA 328P", "ESP32 - WROOM - 32").
    public static func tokens(_ words: [OCRWord]) -> [Token] {
        var out: [String: Token] = [:]
        var order: [String] = []
        func add(_ text: String, _ conf: Double, _ joined: Bool) {
            let t = normTok(text)
            guard !squash(t).isEmpty else { return }
            if let prev = out[t] { if prev.conf < conf { out[t] = Token(text: t, conf: conf, joined: joined) } } else { out[t] = Token(text: t, conf: conf, joined: joined); order.append(t) }
        }
        var lines: [Int: [OCRWord]] = [:]
        var lineOrder: [Int] = []
        for w in words where !w.text.trimmed.isEmpty {
            add(w.text, w.conf, false)
            if lines[w.line] == nil { lineOrder.append(w.line) }
            lines[w.line, default: []].append(w)
        }
        for key in lineOrder {
            let ws = lines[key]!
            for i in ws.indices {
                for n in 2...3 where i + n <= ws.count {
                    let part = ws[i..<(i + n)], conf = part.map(\.conf).min()!
                    add(part.map { $0.text.trimmed }.joined(), conf, true)
                    add(part.map { $0.text.trimmed }.joined(separator: " "), conf, true)
                }
            }
        }
        return order.map { out[$0]! }
    }

    /// Plain text (one line per line) → words.
    public static func words(_ text: String) -> [OCRWord] {
        text.components(separatedBy: "\n").enumerated().flatMap { li, ln in
            ln.split(whereSeparator: \.isWhitespace).map { OCRWord(text: String($0), conf: 100, line: li) }
        }
    }

    // ------------------------------------------------------------ matching a mark
    public struct MarkMatch: Equatable, Sendable { public var score: Double; public var how: String }

    private static func isDigit(_ c: Character?) -> Bool { c.map { $0.isASCII && $0.isNumber } ?? false }
    private static func isLetter(_ c: Character?) -> Bool { c.map { $0.isASCII && $0.isUppercase } ?? false }
    private static func indexOf(_ hay: [Character], _ needle: [Character]) -> Int? {
        guard needle.count <= hay.count, !needle.isEmpty else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    /// How well a token matches a marking (0–1), and how. Exact > with a suffix (ATMEGA328P-PU) >
    /// inside a longer number (SN74HC595N) > with OCR look-alikes > one character wrong. A suffix
    /// that continues a number ("LM3580") does not count; short marks must match exactly.
    public static func markScore(_ token: String, _ mark: String) -> MarkMatch? {
        let t = Array(squash(token)), m = Array(squash(mark))
        guard !t.isEmpty, !m.isEmpty else { return nil }
        let multi = mark.trimmed.contains { $0.isWhitespace }
        if m.count < 4 { return t == m ? MarkMatch(score: 0.7, how: "exact") : nil }
        let mEndsDigit = isDigit(m.last), mStartsDigit = isDigit(m.first), mStartsLetter = isLetter(m.first)
        func okNext(_ s: [Character], _ at: Int) -> Bool { at >= s.count || !(isDigit(s[at]) && mEndsDigit) }
        func okPrev(_ s: [Character], _ at: Int) -> Bool {
            at == 0 || (!(isDigit(s[at - 1]) && mStartsDigit) && !(isLetter(s[at - 1]) && mStartsLetter && m.count < 6))
        }
        if t == m { return .init(score: 1, how: "exact") }
        if t.starts(with: m) && okNext(t, m.count) && !multi { return .init(score: 0.95, how: "with a suffix") }
        if let at = indexOf(t, m), at > 0, okNext(t, at + m.count), okPrev(t, at), !multi { return .init(score: 0.88, how: "inside a longer number") }
        let ct = Array(canon(token)), cm = Array(canon(mark))
        if ct == cm { return .init(score: 0.85, how: "allowing for OCR look-alikes") }
        if ct.starts(with: cm) && okNext(t, m.count) && !multi { return .init(score: 0.8, how: "allowing for OCR look-alikes") }
        if let at = indexOf(ct, cm), at > 0, okNext(ct, at + cm.count), okPrev(ct, at), !multi { return .init(score: 0.74, how: "allowing for OCR look-alikes") }
        if cm.count >= 6 {
            let head = String(ct.prefix(cm.count))
            let d = min(lev(head, String(cm), max: 1), lev(String(ct), String(cm), max: 1))
            if d == 1 && !multi { return .init(score: 0.6, how: "one character different") }
        }
        return nil
    }

    public struct CatalogMatch: Sendable { public var entry: CatalogEntry; public var score: Double; public var token, mark, how: String; public var conf: Double; public var mfrSeen = false }

    static func confWeight(_ conf: Double) -> Double { 0.6 + 0.4 * Swift.max(0, Swift.min(100, conf)) / 100 }

    public static func matchCatalog(_ toks: [Token], catalog: Catalog = .shared) -> [CatalogMatch] {
        let allText = " " + toks.map(\.text).joined(separator: " ") + " "
        var out: [CatalogMatch] = []
        for e in catalog.entries {
            var best: CatalogMatch?
            for mark in e.marks ?? [] {
                for tk in toks {
                    guard let r = markScore(tk.text, mark) else { continue }
                    var score = r.score * confWeight(tk.conf)
                    if tk.joined { score *= 0.97 }
                    if best == nil || best!.score < score { best = CatalogMatch(entry: e, score: score, token: tk.text, mark: mark, how: r.how, conf: tk.conf) }
                }
            }
            if var b = best {
                if (e.mfrWords ?? []).contains(where: { w in RE("[\\s/]" + NSRegularExpression.escapedPattern(for: w) + "[\\s/]").test(allText) }) {
                    b.score = Swift.min(1, b.score + 0.05); b.mfrSeen = true
                }
                out.append(b)
            }
        }
        return out.sorted { $0.score > $1.score }
    }

    public struct InventoryMatch: Sendable { public var part: InventoryRef; public var score: Double; public var token, mark, how: String }

    /// Parts in the inventory whose MPN or supplier number appears in the tokens.
    public static func matchInventory(_ toks: [Token], _ parts: [InventoryRef]) -> [InventoryMatch] {
        var out: [InventoryMatch] = []
        for p in parts {
            let marks = ([p.mpn] + p.supplierPNs).filter { squash($0).count >= 4 }
            var best: InventoryMatch?
            for mark in marks { for tk in toks {
                guard let r = markScore(tk.text, mark) else { continue }
                let score = r.score * confWeight(tk.conf)
                if best == nil || best!.score < score { best = InventoryMatch(part: p, score: score, token: tk.text, mark: mark, how: r.how) }
            } }
            if let best { out.append(best) }
        }
        return out.sorted { $0.score > $1.score }
    }

    // ------------------------------------------------------------ unknown part numbers
    static let notPN = RE("^(REV|VER|V)\\d+(\\.\\d+)*$|^\\d{1,3}(\\.\\d+)?V$|^\\d+(MHZ|KHZ|HZ|MA|MAH|UF|NF|PF|MM)$|^(GND|VCC|VIN|VOUT|SDA|SCL|TX|RX|RST|TXD|RXD|USB|PWR|LED\\d*|RESET|BOOT|EN|3V3|5V)$")

    /// How much a token looks like a part number (0 = not at all): letters and digits, 4+ long.
    public static func partNumberLikeness(_ token: String) -> Double {
        let t = normTok(token), s = squash(t)
        guard (4...24).contains(s.count), RE("[A-Z]").test(s), RE("\\d").test(s), !notPN.test(s), !RE("^\\d{4}[A-Z]?$").test(s) else { return 0 }
        var x = 0.4
        if RE("^[A-Z]{2,5}\\d{2,}").test(s) { x += 0.3 }
        if RE("^\\d{1,2}[A-Z]{1,3}\\d{2,}").test(s) { x += 0.2 }
        if RE("[A-Z]$").test(s) || t.contains("-") { x += 0.05 }
        if RE("^[A-Z]\\d[A-Z]\\d").test(s) || RE("(\\d[A-Z]){3,}").test(s) { x -= 0.2 }
        return Swift.max(0, Swift.min(1, x))
    }

    public struct Unknown: Sendable { public var text: String; public var likeness: Double; public var conf: Double; public var joined: Bool }

    /// Tokens that look like part numbers and match nothing known well.
    public static func unknownNumbers(_ toks: [Token], covered knownTokens: [String], limit: Int = 6) -> [Unknown] {
        let covered = knownTokens.map(squash).filter { !$0.isEmpty }
        var out: [Unknown] = []
        for tk in toks {
            if tk.joined && !RE("\\d").test(tk.text.components(separatedBy: " ").last ?? "") { continue }
            let s = squash(tk.text)
            if covered.contains(where: { $0.contains(s) || s.contains($0) }) { continue }
            let l = partNumberLikeness(tk.text)
            if l <= 0.35 { continue }
            out.append(Unknown(text: RE("\\s+").replace(tk.text, ""), likeness: l, conf: tk.conf, joined: tk.joined))
        }
        func val(_ x: Unknown) -> Double { x.likeness * (0.5 + x.conf / 200) * (x.joined ? 0.8 : 1) }
        var kept: [Unknown] = []
        for x in out.sorted(by: { val($0) > val($1) }) {
            let k = squash(x.text)
            if kept.contains(where: { let j = squash($0.text); return j.contains(k) || k.contains(j) }) { continue }
            kept.append(x)
        }
        return Array(kept.prefix(limit))
    }

    // ------------------------------------------------------------ recognising by look, in two steps
    /// How much step one says "a board or module" (0–1): whether asking which board is worth it.
    public static func boardShare(_ kinds: [LookScore], catalog: Catalog = .shared) -> Double {
        kinds.filter { catalog.boardish.contains($0.ref) }.reduce(0) { $0 + $1.score }
    }
    /// Step one's kinds plus step two's boards, the boards weighted by how board-like the picture is.
    public static func combine(kinds: [LookScore], boards: [LookScore], catalog: Catalog = .shared) -> [LookScore] {
        let share = boardShare(kinds, catalog: catalog)
        return (kinds + boards.map { LookScore(ref: $0.ref, score: $0.score * share) }).sorted { $0.score > $1.score }
    }

    // ------------------------------------------------------------ one ranked list
    public enum Mode: String, Sendable, CaseIterable { case auto, chip, board }

    private static func pct(_ x: Double) -> Int { Int((x * 100).rounded()) }

    /// Merge marking matches, look scores, inventory matches and unknown numbers into one list, best
    /// first. A marking match counts most; a look agreeing with it adds a little; a look alone gives a
    /// weaker candidate; generic kinds only suggest what sort of part it is.
    public static func rank(tokens toks: [Token], look: [LookScore] = [], inventory: [InventoryRef] = [], mode: Mode = .auto,
                            catalog: Catalog = .shared) -> [Candidate] {
        let marks = matchCatalog(toks, catalog: catalog)
        let inv = matchInventory(toks, inventory)
        var cands: [String: Candidate] = [:]
        var order: [String] = []
        func put(_ c: Candidate) {
            if var prev = cands[c.id] { prev.score = Swift.max(prev.score, c.score); prev.reasons += c.reasons; cands[c.id] = prev }
            else { cands[c.id] = c; order.append(c.id) }
        }
        for m in marks where m.score >= 0.45 {
            let how = m.how == "exact" ? "exactly" : m.how
            let read = m.conf < 100 ? " (read at \(Int(m.conf.rounded()))%)" : ""
            let maker = m.mfrSeen ? ", and the maker’s name is printed too" : ""
            put(Candidate(id: "c:" + m.entry.id, source: .catalog(m.entry), score: m.score, reasons: ["Marking “\(m.token)” matches \(m.mark) \(how)\(read)\(maker)"]))
        }
        let top = look.first?.score ?? 0
        for c in look.prefix(6) where c.score >= 0.05 {
            if let e = catalog.entry(c.ref) {
                let key = "c:" + e.id
                let reason = "Looks like \(e.displayName) (\(pct(c.score))% of the picture match)"
                if var x = cands[key] { x.score = Swift.min(0.99, x.score + 0.1 * c.score + 0.05); x.reasons.append(reason); cands[key] = x }
                else { put(Candidate(id: key, source: .catalog(e), score: Swift.min(0.75, c.score * 0.8 + (c.score == top ? 0.05 : 0)), byLook: true, reasons: [reason])) }
            } else if let g = catalog.genericKind(c.ref), c.score >= Swift.max(0.08, top * 0.3) {
                put(Candidate(id: "g:" + g.id, source: .generic(g), score: Swift.min(0.6, 0.15 + c.score * 0.6), reasons: ["Looks like \(g.name.lowercased()) (\(pct(c.score))%)"]))
            }
        }
        for m in inv where m.score >= 0.5 {
            put(Candidate(id: "p:" + m.part.id, source: .inventory(m.part), score: Swift.min(1, m.score + 0.02),
                          reasons: ["Already in your inventory: “\(m.token)” matches \(m.mark)\(m.how == "exact" ? "" : " " + m.how)"]))
        }
        let covered = marks.filter { $0.score >= 0.7 }.map(\.token) + inv.filter { $0.score >= 0.7 }.map(\.token)
        for u in unknownNumbers(toks, covered: covered) {
            let read = u.conf < 100 ? " (read at \(Int(u.conf.rounded()))%)" : ""
            put(Candidate(id: "u:" + squash(u.text), source: .unknown(u.text), score: Swift.min(0.45, 0.15 + u.likeness * 0.3 * (0.5 + u.conf / 200)),
                          reasons: ["“\(u.text)” looks like a part number\(read) — not in the built-in list"]))
        }
        var list = order.map { cands[$0]! }
        func isUnknown(_ c: Candidate) -> Bool { if case .unknown = c.source { return true }; return false }
        func isGeneric(_ c: Candidate) -> Bool { if case .generic = c.source { return true }; return false }
        func isInventory(_ c: Candidate) -> Bool { if case .inventory = c.source { return true }; return false }
        let sure = list.contains { !$0.byLook && !isUnknown($0) && !isGeneric($0) && $0.score >= 0.85 }
        list = list.filter { !($0.byLook || isGeneric($0)) || $0.score >= (sure ? 0.3 : 0.1) }
        for i in list.indices {
            guard case .catalog(let e) = list[i].source else { continue }
            if mode == .chip && e.kind == "board" { list[i].score *= 0.7 }
            if mode == .board && (e.kind == "ic" || e.kind == "discrete") { list[i].score *= 0.8 }
        }
        return list.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            if isUnknown(a.element) != isUnknown(b.element) { return !isUnknown(a.element) }
            // what you already have comes first
            if isInventory(a.element) != isInventory(b.element) { return isInventory(a.element) }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Is the top candidate sure enough that recognising by look isn't needed?
    public static func sure(_ list: [Candidate]) -> Bool {
        guard let c = list.first, c.score >= 0.85 else { return false }
        switch c.source { case .catalog, .inventory: return !c.byLook; default: return false }
    }

    public static func confidence(_ s: Double) -> String { s >= 0.85 ? "strong" : s >= 0.6 ? "likely" : s >= 0.4 ? "possible" : "weak" }

    // ------------------------------------------------------------ to the inventory
    static let kindFor = ["Semiconductors/Transistors": "Q", "Semiconductors/Diodes": "D", "Optoelectronics/LEDs": "LED"]

    /// A new part's fields for a candidate.
    public static func draft(_ c: Candidate, ocrText: String = "", at: Date = .now) -> PartDraft {
        let date = ISO8601DateFormatter.string(from: at, timeZone: .gmt, formatOptions: [.withFullDate])
        let read = ocrText.isEmpty ? "" : "\nMarkings read: " + String(RE("\\s+").replace(ocrText, " ").trimmed.prefix(300))
        var d = PartDraft()
        d.notes = "Identified from a photo on \(date)\(c.reasons.first.map { ": " + $0 } ?? "")." + read
        d.tags = ["identified"]
        switch c.source {
        case .catalog(let e):
            let kind = e.kind == "ic" ? "U" : kindFor[e.cat] ?? (e.cat.hasPrefix("Electromechanical/Relays") ? "K" : nil)
            d.mpn = e.mpn; d.manufacturer = e.mfr
            d.description = e.name.map { "\($0) — \(e.desc)" } ?? e.desc
            d.category = e.cat
            d.package = e.pkg == "Board" || e.pkg == "Module" ? "" : e.pkg.components(separatedBy: " / ")[0]
            d.datasheet = e.ds ?? ""
            if let kind, kind != "K" { d.params.kind = kind }
            d.tags.append(e.kind)
        case .generic(let g):
            let n = RE("^(an?)\\s+", .caseInsensitive).replace(g.name, "")
            d.description = n.prefix(1).uppercased() + n.dropFirst()
            d.category = g.cat
        case .unknown(let text):
            d.mpn = text
        case .reading(let r):
            d.mpn = r.mpn; d.manufacturer = r.manufacturer; d.description = r.description; d.category = r.category; d.package = r.package
            d.params = Values.params(from: [r.description, r.package].joined(separator: " "))
            d.tags.append("apple-intelligence")
        case .inventory:
            break
        }
        return d
    }

    public struct SearchLink: Sendable, Identifiable, Hashable { public var id, name: String; public var url: URL }

    /// Where to look a number up by hand, or find its datasheet.
    public static func searchLinks(_ pn: String) -> [SearchLink] {
        let q = pn.trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let pairs: [(String, String, String)] = [
            ("octopart", "Octopart", "https://octopart.com/search?q=\(q)"),
            ("digikey", "Digi-Key", "https://www.digikey.com/en/products/result?keywords=\(q)"),
            ("mouser", "Mouser", "https://www.mouser.com/c/?q=\(q)"),
            ("lcsc", "LCSC", "https://www.lcsc.com/search?q=\(q)"),
            ("ebay", "eBay", "https://www.ebay.com/sch/i.html?_nkw=\(q)"),
            ("alldatasheet", "AllDatasheet", "https://www.alldatasheet.com/view.jsp?Searchword=\(q)"),
            ("datasheet", "Web: datasheet", "https://duckduckgo.com/?q=\(q)+datasheet+pdf"),
            ("images", "Web: images", "https://duckduckgo.com/?q=\(q)&iax=images&ia=images"),
        ]
        return pairs.compactMap { id, name, s in URL(string: s).map { SearchLink(id: id, name: name, url: $0) } }
    }
}
