import Foundation

// Engineering values, packages and part parameters — ported from the web tool's
// parts-inventory-core.js (geekychris.github.io/tools/parts-inventory/), which has the same rules.

/// A part's electrical parameters, stored with the same keys as the web tool's backups.
public struct PartParams: Codable, Equatable, Hashable, Sendable {
    /// R, C, L, D, LED, Q, U, J, Y, F, SW (or nil).
    public var kind: String?
    public var value: Double?
    /// Tolerance as a fraction (0.01 = 1 %).
    public var tol: Double?
    public var voltage: Double?
    public var power: Double?
    public var dielectric: String?
    public var pkg: String?
    /// The kind came from the prefix alone ("100n" → a capacitor).
    public var guessed: Bool?

    public init(kind: String? = nil, value: Double? = nil, tol: Double? = nil, voltage: Double? = nil, power: Double? = nil,
                dielectric: String? = nil, pkg: String? = nil, guessed: Bool? = nil) {
        self.kind = kind; self.value = value; self.tol = tol; self.voltage = voltage; self.power = power
        self.dielectric = dielectric; self.pkg = pkg; self.guessed = guessed
    }

    public var isEmpty: Bool { self == PartParams() }
}

public struct ParsedValue: Equatable, Sendable {
    public var value: Double
    public var unit: String
    /// R, C, L, V, W, A or Hz.
    public var kind: String?
    public var guessed: Bool
}

public enum Values {
    static let prefix: [Character: Int] = ["p": -12, "n": -9, "u": -6, "µ": -6, "μ": -6, "m": -3, "k": 3, "K": 3, "M": 6, "G": 9]
    static let unitKind: [String: String] = ["Ω": "R", "R": "R", "OHM": "R", "OHMS": "R", "F": "C", "H": "L", "V": "V", "W": "W", "A": "A", "HZ": "Hz"]
    public static let kindUnit: [String: String] = ["R": "Ω", "C": "F", "L": "H", "V": "V", "W": "W", "A": "A", "Hz": "Hz"]
    public static let kindName: [String: String] = ["R": "Resistor", "C": "Capacitor", "L": "Inductor", "D": "Diode", "Q": "Transistor", "U": "IC",
                                                    "J": "Connector", "Y": "Crystal", "F": "Fuse", "LED": "LED", "SW": "Switch"]
    public static let dielectrics = ["C0G", "NP0", "X7R", "X5R", "X6S", "X7S", "X8R", "Y5V", "Z5U", "X7T"]

    static func round(_ x: Double, _ d: Int = 4) -> Double { let f = pow(10, Double(d)); return (x * f).rounded() / f }

    private static let reUpperUnit = RE("^([\\d.]+)([UNP])([FH])$")
    private static let reUpperPrefix = RE("^([\\d.]+)([UNP])$")
    private static let reFraction = RE("^(\\d+)/(\\d+)(W|w)$")
    private static let reInfix = RE("^(\\d+)([pnuµμmkKMRV])(\\d{1,2})([A-Za-zΩ]*)$")
    private static let reNumber = RE("^((?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?)([A-Za-zµμΩ]*)$")

    /// Parse a value in engineering notation: "4k7" → 4700 Ω, "0.1uF" → 1e-7 F, "100n" → 1e-7 (a
    /// capacitor, guessed), "1M" → 1e6 Ω, "50V", "1/4W".
    public static func parse(_ input: String) -> ParsedValue? {
        var s = input.trimmed.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[Ωω]", with: "Ω", options: .regularExpression)
            .replacingOccurrences(of: "(?i)ohms?$", with: "Ω", options: .regularExpression)
        if s.isEmpty { return nil }
        s = reUpperUnit.replace(s) { g in g[1]! + g[2]!.lowercased() + g[3]! }
        s = reUpperPrefix.replace(s) { g in g[1]! + g[2]!.lowercased() }
        if let m = reFraction.match(s), let a = Double(m[1]!), let b = Double(m[2]!), b != 0 {
            return ParsedValue(value: a / b, unit: "W", kind: "W", guessed: false)
        }
        if let m = reInfix.match(s) {
            let unit = m[4] ?? "", u = unit.uppercased(), pc = Character(m[2]!)
            if !unit.isEmpty && unitKind[u] == nil && unit != "Ω" { return nil }
            let p = pc == "R" || pc == "V" ? 0 : prefix[pc]!
            let value = Double("\(m[1]!).\(m[3]!)")! * pow(10, Double(p))
            let kind: String? = !unit.isEmpty ? unitKind[u] ?? "R" : pc == "V" ? "V" : "kKMR".contains(pc) ? "R" : "pnuµμ".contains(pc) ? "C" : nil
            return ParsedValue(value: round(value, 15), unit: unit, kind: kind, guessed: unit.isEmpty && pc != "R" && pc != "V")
        }
        guard let m = reNumber.match(s), let num = Double(m[1]!) else { return nil }
        let suf = m[2] ?? ""
        if suf.lowercased().hasPrefix("meg") {
            let rest = String(suf.dropFirst(3))
            return ParsedValue(value: num * 1e6, unit: rest, kind: "R", guessed: rest.isEmpty)
        }
        if suf.isEmpty { return ParsedValue(value: num, unit: "", kind: nil, guessed: false) }
        let U = suf.uppercased()
        if unitKind[U] != nil || suf == "Ω" { return ParsedValue(value: num, unit: suf, kind: unitKind[U] ?? "R", guessed: false) }
        let p = suf.first!, rest = String(suf.dropFirst()), RU = rest.uppercased()
        if let e = prefix[p], rest.isEmpty || unitKind[RU] != nil || rest == "Ω" {
            let kind: String? = !rest.isEmpty ? unitKind[RU] ?? "R" : "kKM".contains(p) ? "R" : "pnuµμ".contains(p) ? "C" : nil
            return ParsedValue(value: round(num * pow(10, Double(e)), 15), unit: rest, kind: kind, guessed: rest.isEmpty)
        }
        return nil
    }

    static let pfx: [Int: String] = [-12: "p", -9: "n", -6: "µ", -3: "m", 0: "", 3: "k", 6: "M", 9: "G"]

    static func precision(_ x: Double, _ sig: Int) -> Double { Double(String(format: "%.\(sig)g", x)) ?? x }
    static func plain(_ x: Double) -> String { x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x) }

    /// Format with an SI prefix: format(4700, "Ω") → "4.7 kΩ".
    public static func format(_ v: Double?, _ unit: String = "", sig: Int = 4) -> String {
        guard let v, v.isFinite else { return "—" }
        if v == 0 { return "0 \(unit)" }
        var e = Int(floor(log10(abs(v)) / 3)) * 3
        e = max(-12, min(9, e))
        var mant = precision(v / pow(10, Double(e)), sig)
        if abs(mant) >= 1000 && e < 9 { e += 3; mant = precision(v / pow(10, Double(e)), sig) }
        return "\(plain(mant)) \(pfx[e]!)\(unit)".trimmed
    }

    /// Equal within a relative tolerance (default 0.1 %): 4.7k = 4700 = 4k7.
    public static func same(_ a: Double?, _ b: Double?, rel: Double = 1e-3) -> Bool {
        guard let a, let b, a.isFinite, b.isFinite else { return false }
        return a == b || abs(a - b) <= rel * max(abs(a), abs(b))
    }

    private static let reTol = RE("^±?\\s*(\\d+(?:\\.\\d+)?)\\s*%$")
    /// "1%", "±5 %" → a fraction.
    public static func tolerance(_ s: String) -> Double? { reTol.match(s.trimmed).flatMap { Double($0[1]!) }.map { $0 / 100 } }

    // ------------------------------------------------------------ packages
    static let chip: [(String, String)] = [("01005", "0402"), ("0201", "0603"), ("0402", "1005"), ("0603", "1608"), ("0805", "2012"), ("1206", "3216"),
                                           ("1210", "3225"), ("1812", "4532"), ("2010", "5025"), ("2512", "6332"), ("2220", "5750"), ("1808", "4520")]
    static let chipImperial = Set(chip.map(\.0))
    static let metricToImperial = Dictionary(uniqueKeysWithValues: chip.map { ($0.1, $0.0) })
    private static let rePkg = RE("^(SOT-?\\d{2,3}(?:-\\d{1,2})?|SOD-?\\d{2,3}[A-Z]?|SOIC-?\\d{1,2}(?:-W)?|SO-?\\d{1,2}|SOP-?\\d{1,2}|SSOP-?\\d{1,2}|TSSOP-?\\d{1,2}|MSOP-?\\d{1,2}|VSSOP-?\\d{1,2}|QFN-?\\d{1,3}|DFN-?\\d{1,2}|LQFP-?\\d{1,3}|TQFP-?\\d{1,3}|QFP-?\\d{1,3}|BGA-?\\d{1,4}|DIP-?\\d{1,2}|PDIP-?\\d{1,2}|TO-?\\d{1,3}(?:-\\d)?|D2?PAK|DPAK|SMA|SMB|SMC|MELF|MINIMELF|SC-?\\d{2}(?:-\\d)?|SOT-?\\d{3}-\\d|WLCSP-?\\d+|LGA-?\\d+|DO-?\\d{2,3}[A-Z]{0,2})$", .caseInsensitive)
    private static let reKicadMetric = RE("(?:^|[_\\s(-])(\\d{4})_(\\d{4})Metric", .caseInsensitive)
    private static let reParenMetric = RE("(?:^|\\D)(\\d{4,5})\\s*\\(\\s*(\\d{4})\\s*Metric\\s*\\)", .caseInsensitive)
    private static let reMetricOnly = RE("^(\\d{4})\\s*(?:M|Metric|mm)$", .caseInsensitive)
    private static let reChipCode = RE("(?:^|[^\\d])(01005|0201|0402|0603|0805|1206|1210|1812|2010|2512|2220|1808)(?:[^\\d]|$)")
    private static let reChipShape = RE("^(?:[A-Z]{1,3}_)?\\d{4,5}(?:_|$)|^\\d{4,5}$|^(?:R|C|L|D|LED|F)_?\\d{4,5}", .caseInsensitive)
    private static let reDigikeyPkg = RE("^(\\d{1,3})-?(SOIC|DIP|PDIP|SSOP|TSSOP|MSOP|VSSOP|SOP|QFN|DFN|LQFP|TQFP|VQFN|WQFN|UQFN)\\b", .caseInsensitive)

    /// Normalise a package or footprint: "R_0603_1608Metric", "1608 Metric" → "0603"; "SOT23" → "SOT-23"; "8-SOIC" → "SOIC-8".
    public static func normPackage(_ input: String) -> String {
        var s = input.trimmed
        if s.isEmpty { return "" }
        s = RE("^.*:").replace(s, "")
        if let m = reKicadMetric.match(s), chipImperial.contains(m[1]!) { return m[1]! }
        if let m = reParenMetric.match(s), chipImperial.contains(m[1]!) { return m[1]! }
        if let m = reMetricOnly.match(s), let i = metricToImperial[m[1]!] { return i }
        if let m = reChipCode.match(s), reChipShape.test(RE("\\s.*$").replace(s, "")) { return m[1]! }
        if let m = reDigikeyPkg.match(s) { return m[2]!.uppercased() + "-" + m[1]! }
        let t = RE("^[A-Za-z]+_").replace(s, "").split(whereSeparator: { "_ ,\t".contains($0) }).first.map(String.init) ?? ""
        if rePkg.test(t) {
            let u = RE("^([A-Z]+)-?(\\d)").replace(t.uppercased(), "$1-$2")
            return u.hasPrefix("D-2PAK") ? "D2PAK" + u.dropFirst(6) : u
        }
        return ""
    }

    // ------------------------------------------------------------ parameters from text
    private static let leadKinds: [(RE, String)] = [
        (RE("^(RES|RESISTOR|RES\\s+SMD|RES\\s+THICK|RES\\s+THIN)\\b"), "R"), (RE("^(CAP|CAPACITOR)\\b"), "C"),
        (RE("^(IND|INDUCTOR|FIXED IND)\\b"), "L"), (RE("^(LED)\\b"), "LED"), (RE("^(DIODE|SCHOTTKY|ZENER|TVS)\\b"), "D"),
        (RE("^(MOSFET|TRANS|BJT)\\b"), "Q"), (RE("^(IC|MCU)\\b"), "U"), (RE("^(CONN|HEADER)\\b"), "J"), (RE("^(CRYSTAL|XTAL|RESONATOR)\\b"), "Y"),
    ]
    private static let reJoinUnit = RE("(\\d)\\s+(OHMS?|Ω|[pnuµμ]?F|[pnuµμm]?H|[kM]Ω|K?OHMS?)\\b", .caseInsensitive)

    /// Pull parameters out of free text: "RES 10K OHM 1% 1/10W 0603" → R, 10 kΩ, 1 %, 0.1 W, 0603.
    public static func params(from text: String, kind hintKind: String? = nil, footprint: String? = nil) -> PartParams {
        var out = PartParams()
        let raw = text.trimmed, T = raw.uppercased()
        out.kind = leadKinds.first { $0.0.test(T) }?.1
        if out.kind == nil, let hintKind { out.kind = hintKind }
        let kindKnown = out.kind != nil
        let joined = RE("±\\s+").replace(reJoinUnit.replace(raw, "$1$2"), "±")
        for tk in joined.split(whereSeparator: { " \t\n,;".contains($0) }) {
            let t = String(tk).replacingOccurrences(of: "[()]", with: "", options: .regularExpression)
            let U = t.uppercased()
            if out.pkg == nil {
                let p = normPackage(t)
                if !p.isEmpty && (chipImperial.contains(p) ? RE("^\\d{4,5}$").test(t) || RE("Metric|_").test(t) : true) { out.pkg = p; continue }
            }
            if let tol = tolerance(t) { out.tol = tol; continue }
            if dielectrics.contains(U) { out.dielectric = U == "NP0" ? "C0G" : U; continue }
            guard let v = parse(t) else { continue }
            if v.kind == "V" { if out.voltage == nil { out.voltage = v.value }; continue }
            if v.kind == "W" { if out.power == nil { out.power = v.value }; continue }
            guard let vk = v.kind, ["R", "C", "L"].contains(vk), out.value == nil else { continue }
            if kindKnown {
                guard let k = out.kind, ["R", "C", "L"].contains(k), v.guessed || vk == k else { continue }
                out.value = v.value; continue
            }
            out.value = v.value; out.kind = vk
            if v.guessed { out.guessed = true }
        }
        if let footprint, out.pkg == nil { let p = normPackage(footprint); if !p.isEmpty { out.pkg = p } }
        return out
    }

    /// Reference designator → kind: R12 → R, C3 → C, U5/IC1 → U.
    public static func kind(fromRef ref: String) -> String? {
        guard let m = RE("^([A-Za-z]+)\\d").match(ref.trimmed) else { return nil }
        return ["R": "R", "RN": "R", "RV": "R", "C": "C", "L": "L", "FB": "L", "D": "D", "LED": "LED", "Q": "Q", "U": "U", "IC": "U", "J": "J", "P": "J",
                "CN": "J", "CON": "J", "Y": "Y", "X": "Y", "F": "F", "SW": "SW", "S": "SW"][m[1]!.uppercased()]
    }

    /// One line: "10 kΩ ±1% 0.1 W 0603".
    public static func summary(_ p: PartParams) -> String {
        var bits: [String] = []
        if let v = p.value { bits.append(format(v, kindUnit[p.kind ?? ""] ?? "")) }
        if let t = p.tol { bits.append("±" + plain(round(t * 100, 3)) + "%") }
        if let v = p.voltage { bits.append(format(v, "V")) }
        if let w = p.power { bits.append(format(w, "W")) }
        if let d = p.dielectric { bits.append(d) }
        if let k = p.pkg, !k.isEmpty { bits.append(k) }
        return bits.joined(separator: " ")
    }
}
