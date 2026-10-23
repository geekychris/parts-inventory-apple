import Foundation

/// The repository's Markdown pages, as GitHub renders them.
public enum Markdown {
    /// Text for a table cell or a line: Markdown's punctuation and the table's pipes escaped, lines joined.
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") {
            if "\\`*_[]<>|#~!".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// A link target: web links only, with the characters that would end it (or a table cell) encoded.
    public static func url(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = t.split(separator: ":", maxSplits: 1).first?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        var out = ""
        for ch in t {
            switch ch {
            case " ": out += "%20"
            case "(": out += "%28"
            case ")": out += "%29"
            case "|": out += "%7C"
            case "<": out += "%3C"
            case ">": out += "%3E"
            case "\"": out += "%22"
            default: out.append(ch)
            }
        }
        return out
    }

    public static func link(_ text: String, _ target: String) -> String { "[\(escape(text))](\(target))" }

    static func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |\n" }

    /// Anchors for a category page's groups and the levels above them ("Capacitors", "Capacitors › Ceramic"),
    /// unique within the page.
    public static func anchors(_ page: Repository.CategoryPage) -> [[String]: String] {
        var out: [[String]: String] = [:], used = Set<String>()
        for g in page.groups {
            for n in stride(from: 1, through: g.path.count, by: 1) where out[Array(g.path.prefix(n))] == nil {
                let base = Repository.slug(g.path.prefix(n).joined(separator: " "))
                var s = base, k = 2
                while used.contains(s) { s = "\(base)-\(k)"; k += 1 }
                used.insert(s); out[Array(g.path.prefix(n))] = s
            }
        }
        return out
    }

    static func partsUnits(_ parts: Int, _ units: Int) -> String {
        "\(Export.count(parts)) part\(parts == 1 ? "" : "s"), \(Export.count(units)) unit\(units == 1 ? "" : "s")"
    }

    // ------------------------------------------------------------ README.md

    public static func readme(name: String, exported: Date, rows: [InventoryRow], pages: [Repository.CategoryPage], full: Bool, photos: Bool) -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Parts inventory" : name
        let units = rows.reduce(0) { $0 + $1.qty }
        var md = "# \(escape(title))\n\n"
        md += "**\(partsUnits(rows.count, units))** in \(pages.count) categor\(pages.count == 1 ? "y" : "ies"). "
        md += "Exported \(Export.isoDate(exported)) from [Parts Inventory](https://github.com/geekychris/parts-inventory-apple).\n\n"
        md += "- [All parts](parts.csv) — one table, searchable on GitHub\n"
        md += "- [inventory.json](inventory.json) — the inventory for the app to read: parts and locations"
        md += full ? ", projects and stock history\n" : "\n"
        if photos { md += "- [Photos](photos/)\n" }

        md += "\n## Categories\n\n"
        if pages.isEmpty { md += "No parts yet.\n" }
        for page in pages {
            let file = "categories/\(page.slug).md"
            md += "- " + link(page.title, file) + " — \(partsUnits(page.count, page.units))\n"
            // The levels below, with the parts at or under each.
            let anchors = anchors(page)
            var counts: [[String]: Int] = [:]
            for g in page.groups { for n in stride(from: 1, through: g.path.count, by: 1) { counts[Array(g.path.prefix(n)), default: 0] += g.rows.count } }
            let paths = counts.keys.sorted { Export.less($0.joined(separator: "\u{1}"), $1.joined(separator: "\u{1}")) }
            for p in paths {
                md += String(repeating: "  ", count: p.count) + "- " + link(p.last!, "\(file)#\(anchors[p]!)") + " — \(Export.count(counts[p]!))\n"
            }
        }

        let low = rows.filter(\.isLow).sorted { a, b in a.title != b.title ? Export.less(a.title, b.title) : a.id < b.id }
        md += "\n## Low stock\n\n"
        if low.isEmpty { md += "Nothing is running low.\n" } else {
            var where_: [String: String] = [:]
            for page in pages {
                let anchors = anchors(page)
                for g in page.groups { for r in g.rows { where_[r.id] = "categories/\(page.slug).md" + (g.path.isEmpty ? "" : "#\(anchors[g.path]!)") } }
            }
            md += row(["Part", "Description", "Qty", "Low at", "Location"]) + row(["---", "---", "--:", "--:", "---"])
            for r in low {
                md += row([link(r.title, where_[r.id] ?? "parts.csv"), escape(r.description), String(r.qty), r.lowStock.map(String.init) ?? "", escape(r.location)])
            }
        }
        md += "\n---\n\nWritten by the app: edit the inventory there and export again — changes made to these files by hand are replaced. "
        md += "The format is described in [repository-format.md](https://github.com/geekychris/parts-inventory-apple/blob/main/docs/repository-format.md).\n"
        return md
    }

    // ------------------------------------------------------------ categories/<slug>.md

    /// `photos`: a part's photo file by part id, when photos are exported.
    public static func categoryPage(_ page: Repository.CategoryPage, inventory: String, photos: [String: String]?) -> String {
        let title = inventory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Parts inventory" : inventory
        var md = "# \(escape(page.title))\n\n"
        md += "[\(escape(title))](../README.md) · \(partsUnits(page.count, page.units))\n"
        let anchors = anchors(page)
        var shown = Set<[String]>()
        for g in page.groups {
            md += "\n"
            if !g.path.isEmpty {
                // Anchors for levels with no parts of their own, so the README's links to them land here.
                let above = (1..<g.path.count).map { Array(g.path.prefix($0)) }.filter { !shown.contains($0) }
                let ids = (above + [g.path]).map { "<a id=\"\(anchors[$0]!)\"></a>" }.joined()
                shown.formUnion(above + [g.path])
                md += "## \(ids)\(g.path.map(escape).joined(separator: " › "))\n\n"
            }
            var header = ["MPN", "Manufacturer", "Description", "Value", "Package", "Qty", "Location", "Datasheet", "Suppliers"]
            var align = ["---", "---", "---", "---", "---", "--:", "---", "---", "---"]
            if photos != nil { header.insert("Photo", at: 0); align.insert("---", at: 0) }
            md += row(header) + row(align)
            for r in g.rows {
                let suppliers = r.suppliers.map { s in
                    let text = "\(Export.supplierName(s.supplier)) \(s.pn)"
                    return url(Export.supplierURL(s)).map { link(text, $0) } ?? escape(text)
                }.joined(separator: "<br>")
                var cells = [
                    escape(r.mpn), escape(r.manufacturer), escape(r.description), escape(r.valueText), escape(r.package),
                    r.isLow ? "**\(r.qty)** (low)" : String(r.qty), escape(r.location),
                    url(r.datasheet).map { "[Open](\($0))" } ?? "", suppliers,
                ]
                if let photos {
                    cells.insert(photos[r.id].map { "[<img src=\"../\($0)\" width=\"64\" alt=\"\">](../\($0))" } ?? "", at: 0)
                }
                md += row(cells)
            }
        }
        return md
    }
}
