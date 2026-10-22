import Foundation

/// A compiled regular expression with the few operations the parsers need, so patterns can be
/// ported from the web tool (JavaScript) nearly unchanged. Offsets are UTF-16, as in NSString.
struct RE: @unchecked Sendable {
    let ns: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        ns = try! NSRegularExpression(pattern: pattern, options: options)
    }

    private func all(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

    func test(_ s: String) -> Bool { ns.firstMatch(in: s, range: all(s)) != nil }

    /// The groups of the first match (index 0 is the whole match), or nil.
    func match(_ s: String) -> [String?]? {
        guard let m = ns.firstMatch(in: s, range: all(s)) else { return nil }
        let n = s as NSString
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : n.substring(with: r)
        }
    }

    /// Replace every match; `$1` refers to a group.
    func replace(_ s: String, _ template: String) -> String {
        ns.stringByReplacingMatches(in: s, range: all(s), withTemplate: template)
    }

    /// Replace every match with the result of a function of its groups.
    func replace(_ s: String, _ f: ([String?]) -> String) -> String {
        let n = s as NSString
        var out = ""
        var at = 0
        for m in ns.matches(in: s, range: all(s)) {
            out += n.substring(with: NSRange(location: at, length: m.range.location - at))
            let groups = (0..<m.numberOfRanges).map { i -> String? in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : n.substring(with: r)
            }
            out += f(groups)
            at = m.range.location + m.range.length
        }
        return out + n.substring(from: at)
    }

    /// The UTF-16 offset of the first match, or nil.
    func search(_ s: String) -> Int? { ns.firstMatch(in: s, range: all(s)).map(\.range.location) }
}

extension String {
    /// Trimmed, as the web tool's `str()`.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
