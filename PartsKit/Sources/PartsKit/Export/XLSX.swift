import Foundation

/// An Excel workbook (.xlsx, Office Open XML) with one sheet: a bold, frozen header row with a filter over
/// the data, numbers as numbers, text in a shared-strings table. Written by hand — a ZIP of a few XML parts.
public enum XLSX {
    public static func data(_ table: ExportTable, sheetName: String = "Parts") -> Data {
        var strings: [String] = [], index: [String: Int] = [:]
        func shared(_ text: String) -> Int {
            let s = String(text.prefix(32_767))   // Excel's limit for a cell
            if let i = index[s] { return i }
            strings.append(s); index[s] = strings.count - 1
            return strings.count - 1
        }
        let cols = table.header.count
        let last = column(max(cols - 1, 0)) + String(table.rows.count + 1)

        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <dimension ref="A1:\(last)"/>\
        <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>\
        <selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>\
        <sheetFormatPr defaultRowHeight="15"/><cols>
        """
        for (i, w) in table.widths.enumerated() { sheet += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(Values.plain(w))\" customWidth=\"1\"/>" }
        sheet += "</cols><sheetData>"
        func row(_ n: Int, _ cells: [ExportTable.Cell], style: Int) {
            sheet += "<row r=\"\(n)\">"
            for (i, c) in cells.enumerated() {
                let ref = column(i) + String(n), s = style > 0 ? " s=\"\(style)\"" : ""
                switch c {
                case .number(let v) where v.isFinite: sheet += "<c r=\"\(ref)\"\(s)><v>\(Values.plain(v))</v></c>"
                case .number: break
                case .text(let t) where t.isEmpty: break
                case .text(let t): sheet += "<c r=\"\(ref)\"\(s) t=\"s\"><v>\(shared(t))</v></c>"
                }
            }
            sheet += "</row>"
        }
        row(1, table.header.map { .text($0) }, style: 1)
        for (i, r) in table.rows.enumerated() { row(i + 2, r, style: 0) }
        sheet += "</sheetData><autoFilter ref=\"A1:\(last)\"/>"
        sheet += "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/></worksheet>"

        var sst = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(strings.count)" uniqueCount="\(strings.count)">
        """
        for s in strings { sst += "<si><t xml:space=\"preserve\">\(escape(s))</t></si>" }
        sst += "</sst>"

        let name = escape(String(sheetName.filter { !"[]:*?/\\".contains($0) }.prefix(31)))
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>\
        </Types>
        """.utf8))
        zip.add("_rels/.rels", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """.utf8))
        zip.add("xl/workbook.xml", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="\(name)" sheetId="1" r:id="rId1"/></sheets>\
        <definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">'\(name.replacingOccurrences(of: "'", with: "''"))'!$A$1:$\(column(max(cols - 1, 0)))$\(table.rows.count + 1)</definedName></definedNames>\
        </workbook>
        """.utf8))
        zip.add("xl/_rels/workbook.xml.rels", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>\
        </Relationships>
        """.utf8))
        zip.add("xl/worksheets/sheet1.xml", Data(sheet.utf8))
        zip.add("xl/styles.xml", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """.utf8))
        zip.add("xl/sharedStrings.xml", Data(sst.utf8))
        return zip.finished()
    }

    /// "A" for 0, "Z" for 25, "AA" for 26.
    public static func column(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(UInt8(65 + r))) + s; n = (n - 1) / 26 }
        return s
    }

    /// Text for XML: the five entities escaped, characters XML 1.0 can't hold dropped.
    public static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            case _ where u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF: break
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }
}
