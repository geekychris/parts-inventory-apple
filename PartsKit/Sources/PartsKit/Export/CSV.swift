import Foundation

/// CSV as RFC 4180 has it: fields with a comma, quote, or line break are quoted, quotes doubled.
///
/// The defaults suit Excel and Numbers: UTF-8 with a byte-order mark (without it Excel reads "Ω" as "Î©")
/// and CRLF line ends. The repository's `parts.csv` uses `.plain` — no mark, LF — which is kinder to git.
public enum CSV {
    public struct Options: Sendable {
        public var byteOrderMark: Bool
        public var lineEnd: String
        public init(byteOrderMark: Bool = true, lineEnd: String = "\r\n") { self.byteOrderMark = byteOrderMark; self.lineEnd = lineEnd }
        public static let excel = Options()
        public static let plain = Options(byteOrderMark: false, lineEnd: "\n")
    }

    /// A field, quoted when it needs to be.
    public static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || s.first == " " || s.last == " " else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func text(_ table: ExportTable, options: Options = .excel) -> String {
        ([table.header] + table.rows.map { $0.map(\.string) })
            .map { $0.map(field).joined(separator: ",") + options.lineEnd }
            .joined()
    }

    public static func data(_ table: ExportTable, options: Options = .excel) -> Data {
        (options.byteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text(table, options: options).utf8)
    }
}
