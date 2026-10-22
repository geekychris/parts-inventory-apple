import Foundation

/// A parsed search: "10k 0603 1% cat:passives loc:drawer low" → the value, package and tolerance to
/// match, filters, and the remaining words, each of which must appear in the part's text.
public struct PartQuery: Equatable, Sendable {
    public var text: [String] = []
    public var category: String?
    public var location: String?
    public var tag: String?
    public var manufacturer: String?
    public var lowOnly = false
    public var kind: String?
    public var kindGuessed = false
    public var value: Double?
    public var pkg: String?
    public var tol: Double?
    public var voltage: Double?
    public var power: Double?
    public var dielectric: String?

    public var hasParams: Bool { value != nil || pkg != nil || tol != nil || voltage != nil || power != nil || dielectric != nil || kind != nil }
    public var isEmpty: Bool { !hasParams && text.isEmpty && category == nil && location == nil && tag == nil && manufacturer == nil && !lowOnly }

    public init(_ q: String) {
        let toks = RE("\"[^\"]*\"|\\S+").ns.matches(in: q, range: NSRange(location: 0, length: (q as NSString).length)).map { (q as NSString).substring(with: $0.range) }
        for raw in toks {
            let quoted = raw.hasPrefix("\"")
            let tk = raw.replacingOccurrences(of: "^\"|\"$", with: "", options: .regularExpression)
            if tk.isEmpty { continue }
            if quoted { text.append(tk.lowercased()); continue }
            if let m = RE("^(cat|category|loc|location|tag|mfr|pkg|kind):(.+)$", .caseInsensitive).match(tk) {
                let v = m[2]!
                switch m[1]!.lowercased() {
                case "cat", "category": category = v.lowercased()
                case "loc", "location": location = v.lowercased()
                case "tag": tag = v.lowercased()
                case "mfr": manufacturer = v.lowercased()
                case "pkg": pkg = Values.normPackage(v).isEmpty ? v.uppercased() : Values.normPackage(v)
                default: kind = v.uppercased()
                }
                continue
            }
            if tk.lowercased() == "low" { lowOnly = true; continue }
            let p = Values.normPackage(tk)
            if !p.isEmpty && (!Values.chipImperial.contains(p) || RE("^\\d{4,5}$|Metric", .caseInsensitive).test(tk)) && pkg == nil { pkg = p; continue }
            if let t = Values.tolerance(tk) { tol = t; continue }
            let U = tk.uppercased()
            if Values.dielectrics.contains(U) { dielectric = U == "NP0" ? "C0G" : U; continue }
            let v = Values.parse(tk)
            if let v, v.kind == "V" { voltage = v.value; continue }
            if let v, v.kind == "W" { power = v.value; continue }
            if let v, let k = v.kind, value == nil, ["R", "C", "L"].contains(k) {
                value = v.value; if kind == nil { kind = k }; kindGuessed = v.guessed; continue
            }
            text.append(tk.lowercased())
        }
    }

    /// Do a part's parameters satisfy the query? Value equal (0.1 %), same package, tolerance at
    /// least as tight, ratings at least as high, same dielectric.
    public func matches(_ p: PartParams) -> Bool {
        if let value {
            if !Values.same(value, p.value) { return false }
            if let kind, !kindGuessed, let pk = p.kind, pk != kind { return false }
        } else if let kind, p.kind != kind { return false }
        if let pkg, Values.normPackage(p.pkg ?? "") != pkg && (p.pkg ?? "").uppercased() != pkg { return false }
        if let tol, !(p.tol.map { $0 <= tol + 1e-12 } ?? false) { return false }
        if let voltage, !(p.voltage.map { $0 >= voltage - 1e-9 } ?? false) { return false }
        if let power, !(p.power.map { $0 >= power - 1e-12 } ?? false) { return false }
        if let dielectric, p.dielectric != dielectric { return false }
        return true
    }
}
