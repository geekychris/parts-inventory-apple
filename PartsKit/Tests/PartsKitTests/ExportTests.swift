import Foundation
import Testing
@testable import PartsKit

// ------------------------------------------------------------ CSV

@Test func csvQuotesOnlyWhatNeedsIt() {
    #expect(CSV.field("LM358DR") == "LM358DR")
    #expect(CSV.field("10k, 1%") == "\"10k, 1%\"")
    #expect(CSV.field("2\" reel") == "\"2\"\" reel\"")
    #expect(CSV.field("line\nbreak") == "\"line\nbreak\"")
    #expect(CSV.field("cr\rhere") == "\"cr\rhere\"")
    #expect(CSV.field("") == "")
    #expect(CSV.field("10 kΩ ±1%") == "10 kΩ ±1%")
}

@Test func csvLineEndsAndByteOrderMark() {
    let t = ExportTable(header: ["A", "B"], rows: [[.text("x,y"), .number(3)], [.empty, .number(2.5)]])
    let excel = CSV.data(t)
    #expect(Array(excel.prefix(3)) == [0xEF, 0xBB, 0xBF])
    #expect(String(decoding: excel.dropFirst(3), as: UTF8.self) == "A,B\r\n\"x,y\",3\r\n,2.5\r\n")
    let plain = CSV.data(t, options: .plain)
    #expect(String(decoding: plain, as: UTF8.self) == "A,B\n\"x,y\",3\n,2.5\n")
}

func sampleBackup() -> Backup {
    var b = Backup()
    b.locations = [Backup.Location(id: "lb", parentId: "la", name: "Drawer 1"), Backup.Location(id: "la", name: "Cabinet A"),
                   Backup.Location(id: "lc", name: "Shelf")]
    func part(_ id: String, _ mpn: String, _ cat: String, _ qty: Double, _ loc: String?, desc: String = "") -> Backup.Part {
        var p = Backup.Part(id: id)
        p.mpn = mpn; p.category = cat; p.qty = qty; p.locationId = loc; p.description = desc; p.manufacturer = "Maker"
        p.updated = 1_760_000_000_000; p.created = 1_750_000_000_000
        return p
    }
    var lm = part("p3", "LM358DR", "ICs/Analog", 4, "lb", desc: "Op-amp | dual *fast* <8-SOIC>")
    lm.lowStock = 5
    var s = SupplierEntry(supplier: "digikey", pn: "296-1395-1-ND"); s.url = ""
    lm.suppliers = [s, SupplierEntry(supplier: "mouser", pn: "595-LM358DR")]
    lm.datasheet = "https://www.ti.com/lit/ds/symlink/lm358.pdf"
    lm.photoIds = ["ph1"]
    var r = part("p1", "RC0603FR-0710KL", "Passives/Resistors", 480, "lb", desc: "RES 10K OHM 1% 1/10W 0603")
    r.params = PartParams(kind: "R", value: 10_000, tol: 0.01, pkg: "0603")
    b.parts = [
        lm, r,
        part("p2", "CL10B104KB8NNNC", "Passives/Capacitors/Ceramic", 950, "la"),
        part("p4", "ESP32-DevKitC", "Boards", 2, "lc"),
        part("p5", "", "", 1, nil, desc: "Mystery part"),
        part("p6", "AMS1117", "Passives", 3, nil),
    ]
    b.history = [Backup.Change(id: "h1", at: 1_760_000_000_000, partId: "p1", delta: 480, qtyAfter: 480, reason: "Sample")]
    b.photos = [Backup.Photo(id: "ph1", partId: "p3", type: "image/png", name: "lm.png", data: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(), created: 0, updated: 0)]
    return b
}

@Test func tableColumnsAndSuppliers() {
    let rows = sampleBackup().rows()
    let t = InventoryRow.table(rows)
    #expect(t.header.first == "MPN" && t.header.last == "Updated" && !t.header.contains("Source"))
    let lm = rows.first { $0.mpn == "LM358DR" }!
    #expect(lm.supplierNumbers == "Digi-Key: 296-1395-1-ND; Mouser: 595-LM358DR")
    let i = rows.firstIndex { $0.mpn == "LM358DR" }!
    #expect(t.rows[i][6] == .number(4) && t.rows[i][7] == .number(5))
    #expect(t.rows[i][3] == .text("ICs / Analog"))
    #expect(t.rows[i][13] == .text(Export.isoDate(Date(jsTime: 1_760_000_000_000))))
    let withSource = InventoryRow.table(sampleBackup().rows(source: "Sam"))
    #expect(withSource.header.first == "Source" && withSource.rows[0][0] == .text("Sam"))
}

// ------------------------------------------------------------ ZIP and Excel

@Test func crc32KnownVectors() {
    #expect(CRC32.checksum(Data()) == 0)
    #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    #expect(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
}

/// The entries of a ZIP, read the way an unzipper does: from the end record through the central directory.
func readZip(_ d: Data) -> [String: Data] {
    let b = [UInt8](d)
    func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    let end = b.count - 22
    guard end >= 0, u32(end) == 0x0605_4B50 else { return [:] }
    var out: [String: Data] = [:], o = u32(end + 16)
    for _ in 0..<u16(end + 10) {
        guard u32(o) == 0x0201_4B50 else { return [:] }
        let crc = u32(o + 16), size = u32(o + 20), nameLen = u16(o + 28), local = u32(o + 42)
        let name = String(decoding: b[(o + 46)..<(o + 46 + nameLen)], as: UTF8.self)
        guard u32(local) == 0x0403_4B50, u16(local + 26) == nameLen, u32(local + 14) == crc else { return [:] }
        let start = local + 30 + nameLen + u16(local + 28)
        let data = Data(b[start..<(start + size)])
        guard CRC32.checksum(data) == UInt32(crc) else { return [:] }
        out[name] = data
        o += 46 + nameLen + u16(o + 30) + u16(o + 32)
    }
    return out
}

@Test func zipStructure() throws {
    var z = ZipWriter()
    z.add("a.txt", Data("hello".utf8))
    z.add("dir/b – ü.txt", Data())
    let d = z.finished()
    #expect(Array(d.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
    let entries = readZip(d)
    #expect(entries["a.txt"] == Data("hello".utf8))
    #expect(entries["dir/b – ü.txt"] == Data())
    // The same entries give the same bytes.
    var z2 = ZipWriter(); z2.add("a.txt", Data("hello".utf8)); z2.add("dir/b – ü.txt", Data())
    #expect(z2.finished() == d)
    // And the system's unzip agrees, where there is one.
    if FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") {
        let url = FileManager.default.temporaryDirectory.appending(path: "export-test-\(UUID().uuidString).zip")
        try d.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-tq", url.path]
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }
}

@Test func xlsxColumnsAndEscaping() {
    #expect(XLSX.column(0) == "A" && XLSX.column(25) == "Z" && XLSX.column(26) == "AA" && XLSX.column(701) == "ZZ" && XLSX.column(702) == "AAA")
    #expect(XLSX.escape("a<b & \"c\" 'd'>") == "a&lt;b &amp; &quot;c&quot; &apos;d&apos;&gt;")
    #expect(XLSX.escape("bell\u{7}tab\t") == "belltab\t")
}

@Test func xlsxWorkbook() {
    let t = InventoryRow.table(sampleBackup().rows())
    let entries = readZip(XLSX.data(t))
    #expect(Set(entries.keys) == ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
                                  "xl/worksheets/sheet1.xml", "xl/styles.xml", "xl/sharedStrings.xml"])
    let sheet = String(decoding: entries["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
    #expect(sheet.contains("<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"))
    #expect(sheet.contains("<autoFilter ref=\"A1:N7\"/>"))
    #expect(sheet.contains("<c r=\"A1\" s=\"1\" t=\"s\">"))          // a bold header
    #expect(sheet.contains("<v>480</v>"))                              // a quantity, as a number
    let strings = String(decoding: entries["xl/sharedStrings.xml"]!, as: UTF8.self)
    #expect(strings.contains("Op-amp | dual *fast* &lt;8-SOIC&gt;"))
    for (_, xml) in entries { #expect(XMLParserCheck.wellFormed(xml)) }
}

enum XMLParserCheck {
    static func wellFormed(_ d: Data) -> Bool { XMLParser(data: d).parse() }
}

// ------------------------------------------------------------ the repository

let day1 = Date(timeIntervalSince1970: 1_761_000_000), day2 = Date(timeIntervalSince1970: 1_762_000_000)

@Test func repositoryIsDeterministic() throws {
    let a = try Repository.files(sampleBackup(), exported: day1)
    var shuffled = sampleBackup()
    shuffled.parts.reverse(); shuffled.locations.reverse()
    let b = try Repository.files(shuffled, exported: day1)
    #expect(a == b)
    let c = try Repository.files(sampleBackup(), exported: day2)
    #expect(Set(a.keys) == Set(c.keys))
    #expect(a.keys.filter { a[$0] != c[$0] }.sorted() == ["README.md", "inventory.json"])
    #expect(Set(a.keys) == ["inventory.json", "README.md", "parts.csv", "categories/boards.md", "categories/ics.md",
                            "categories/passives.md", "categories/uncategorised.md"])
}

@Test func repositoryJSONRoundTrips() throws {
    let files = try Repository.files(sampleBackup(), exported: day1)
    let json = files["inventory.json"]!
    let (back, warnings) = try Backup.read(json)
    #expect(warnings.isEmpty)
    #expect(back.schema == Backup.schemaName && back.version == 1)
    #expect(back.parts.map(\.id) == ["p5", "p4", "p3", "p6", "p2", "p1"])     // by category, then MPN
    #expect(back.locations.map(\.id) == ["la", "lb", "lc"])                    // by path
    #expect(back.history.isEmpty && back.projects.isEmpty && (back.photos ?? []).isEmpty)
    #expect(!String(decoding: json, as: UTF8.self).contains("\"photos\""))
    #expect(back.parts.allSatisfy { $0.photoIds.isEmpty })
    let key = { (r: InventoryRow) in r.id }
    #expect(back.rows().sorted { key($0) < key($1) } == sampleBackup().rows().sorted { key($0) < key($1) })
    #expect(String(decoding: json, as: UTF8.self).hasSuffix("}\n"))

    let full = try Repository.files(sampleBackup(), options: .init(full: true), exported: day1)
    try #expect(Backup.read(full["inventory.json"]!).backup.history.map(\.id) == ["h1"])
}

@Test func repositoryPhotos() throws {
    let files = try Repository.files(sampleBackup(), options: .init(photos: true), exported: day1)
    #expect(files["photos/ph1.png"] == Data([0x89, 0x50, 0x4E, 0x47]))
    let ics = String(decoding: files["categories/ics.md"]!, as: UTF8.self)
    #expect(ics.contains("[<img src=\"../photos/ph1.png\" width=\"64\" alt=\"\">](../photos/ph1.png)"))
    try #expect(Backup.read(files["inventory.json"]!).backup.parts.first { $0.id == "p3" }?.photoIds == ["ph1"])
}

@Test func slugs() {
    #expect(Repository.slug("Passives") == "passives")
    #expect(Repository.slug("ICs & Modules / Misc.") == "ics-modules-misc")
    #expect(Repository.slug("Résistances") == "resistances")
    #expect(Repository.slug("  --  ") == "category")
    #expect(Repository.slug("Ω") == "o")
    // Categories whose slugs clash get numbered, in order.
    var b = Backup()
    for (i, c) in ["ICs", "ics", "I.C.s"].enumerated() { var p = Backup.Part(id: "p\(i)"); p.category = c; b.parts.append(p) }
    #expect(Repository.categoryPages(b.rows()).map(\.slug) == ["i-c-s", "ics", "ics-2"])
}

@Test func markdownEscaping() {
    #expect(Markdown.escape("Op-amp | dual") == "Op-amp \\| dual")
    #expect(Markdown.escape("*bold* _x_ [y] <z> `c` #1 ~s~ a\\b") == "\\*bold\\* \\_x\\_ \\[y\\] \\<z\\> \\`c\\` \\#1 \\~s\\~ a\\\\b")
    #expect(Markdown.escape("two\nlines\r\nhere") == "two lines here")
    #expect(Markdown.url("javascript:alert(1)") == nil)
    #expect(Markdown.url("https://x.com/a b(c)|d") == "https://x.com/a%20b%28c%29%7Cd")

    let files = try! Repository.files(sampleBackup(), exported: day1)
    let ics = String(decoding: files["categories/ics.md"]!, as: UTF8.self)
    // Each table row keeps its column count: escaped pipes don't split cells.
    let line = ics.split(separator: "\n").first { $0.contains("LM358DR") }!
    #expect(line.replacingOccurrences(of: "\\|", with: "").filter { $0 == "|" }.count == 10)
    #expect(line.contains("Op-amp \\| dual \\*fast\\* \\<8-SOIC\\>"))
    #expect(line.contains("**4** (low)"))
    #expect(line.contains("[Digi-Key 296-1395-1-ND](https://www.digikey.com/en/products/result?keywords=296%2D1395%2D1%2DND)"))
    #expect(ics.contains("## <a id=\"analog\"></a>Analog"))

    let readme = String(decoding: files["README.md"]!, as: UTF8.self)
    #expect(readme.hasPrefix("# Parts inventory\n\n**6 parts, 1,440 units** in 4 categories. Exported \(Export.isoDate(day1))"))
    #expect(readme.contains("- [Passives](categories/passives.md) — 3 parts, 1,433 units\n"))
    #expect(readme.contains("  - [Capacitors](categories/passives.md#capacitors) — 1\n    - [Ceramic](categories/passives.md#capacitors-ceramic) — 1\n"))
    #expect(readme.contains("| [LM358DR](categories/ics.md#analog) |"))
    let passives = String(decoding: files["categories/passives.md"]!, as: UTF8.self)
    #expect(passives.contains("## <a id=\"capacitors\"></a><a id=\"capacitors-ceramic\"></a>Capacitors › Ceramic"))
}

@Test func repositoryWriteReplacesOnlyItsOwnFiles() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appending(path: "repo-test-\(UUID().uuidString)")
    try fm.createDirectory(at: dir.appending(path: ".git"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    try Data("MIT".utf8).write(to: dir.appending(path: "LICENSE"))
    try Data().write(to: dir.appending(path: ".git/HEAD"))

    let first = try Repository.files(sampleBackup(), options: .init(photos: true), exported: day1)
    let w1 = try Repository.write(first, to: dir)
    #expect(w1.written.count == first.count && w1.removed.isEmpty)
    try #expect(Repository.write(first, to: dir).written.isEmpty)     // nothing changed, nothing written

    // Without the boards and without photos: their files go, the rest of the folder stays.
    var b = sampleBackup(); b.parts.removeAll { $0.category == "Boards" }
    let second = try Repository.files(b, exported: day1)
    let w2 = try Repository.write(second, to: dir)
    #expect(w2.removed == ["categories/boards.md", "photos/ph1.png"])
    #expect(!fm.fileExists(atPath: dir.appending(path: "photos").path))
    #expect(fm.fileExists(atPath: dir.appending(path: "LICENSE").path) && fm.fileExists(atPath: dir.appending(path: ".git/HEAD").path))
    try #expect(Data(contentsOf: dir.appending(path: "categories/ics.md")) == second["categories/ics.md"])
}
