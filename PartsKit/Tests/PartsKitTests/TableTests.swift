import Foundation
import Testing
@testable import PartsKit

private func fixture() throws -> Backup {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/friend-inventory/inventory", withExtension: "json"))
    return try RemoteInventory.decode(Data(contentsOf: url))
}

@Test func friendFixtureReadsAsRows() throws {
    let rows = try fixture().rows(source: "Sam")
    #expect(rows.count == 5)
    let cap = try #require(rows.first { $0.mpn == "GRM188R71H104KA93D" })
    #expect(cap.locationPath == ["Workbench", "Drawer 1"] && cap.isLow && cap.source == "Sam")
    #expect(rows.first { $0.id == "p-sam-5" }?.location == "")
}

@Test func folderReading() throws {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/friend-inventory/inventory", withExtension: "json"))
    #expect(try RemoteInventory.read(folder: url.deletingLastPathComponent()).parts.count == 5)
    #expect(throws: RemoteInventory.Failure.self) { try RemoteInventory.read(folder: url.deletingLastPathComponent().deletingLastPathComponent()) }
}

@Test func notAnInventory() {
    #expect(throws: RemoteInventory.Failure.notInventory("The address gave a web page, not inventory.json.")) {
        try RemoteInventory.decode(Data("<!DOCTYPE html><html><body>Not Found</body></html>".utf8))
    }
    #expect(throws: RemoteInventory.Failure.self) { try RemoteInventory.decode(Data(#"{"schema":"something-else","version":1}"#.utf8)) }
}

@Test func resolvesAddresses() throws {
    func r(_ s: String) throws -> String { try RemoteInventory.resolve(s).absoluteString }
    #expect(try r("https://github.com/sam/parts") == "https://raw.githubusercontent.com/sam/parts/HEAD/inventory.json")
    #expect(try r("github.com/sam/parts.git") == "https://raw.githubusercontent.com/sam/parts/HEAD/inventory.json")
    #expect(try r("https://github.com/sam/parts/") == "https://raw.githubusercontent.com/sam/parts/HEAD/inventory.json")
    #expect(try r("https://github.com/sam/stuff/tree/main/parts") == "https://raw.githubusercontent.com/sam/stuff/main/parts/inventory.json")
    #expect(try r("https://github.com/sam/stuff/tree/dev") == "https://raw.githubusercontent.com/sam/stuff/dev/inventory.json")
    #expect(try r("https://github.com/sam/stuff/blob/main/parts/inventory.json") == "https://raw.githubusercontent.com/sam/stuff/main/parts/inventory.json")
    #expect(try r("https://raw.githubusercontent.com/sam/parts/main/inventory.json") == "https://raw.githubusercontent.com/sam/parts/main/inventory.json")
    #expect(try r("https://example.com/sam/inv.JSON") == "https://example.com/sam/inv.JSON")
    #expect(try r("https://example.com/sam/") == "https://example.com/sam/inventory.json")
    #expect(try r("http://127.0.0.1:8000") == "http://127.0.0.1:8000/inventory.json")
    #expect(throws: RemoteInventory.Failure.unsupportedScheme("ftp")) { try RemoteInventory.resolve("ftp://example.com/x") }
    #expect(throws: RemoteInventory.Failure.unsupportedScheme("file")) { try RemoteInventory.resolve("file:///Users/sam/parts") }
    #expect(throws: RemoteInventory.Failure.self) { try RemoteInventory.resolve("https://github.com/sam") }
    #expect(throws: RemoteInventory.Failure.self) { try RemoteInventory.resolve("  ") }
}

@Test func queryMatchesRows() throws {
    let rows = try fixture().rows(source: "Sam")
    func find(_ q: String) -> [String] { rows.filter { PartQuery(q).matches($0) }.map(\.mpn) }
    #expect(find("10k 0805 1%") == ["RC0805FR-0710KL"])
    #expect(find("100n 0603") == ["GRM188R71H104KA93D"])
    #expect(find("cat:passives").count == 2)
    #expect(find("loc:drawer") == ["RC0805FR-0710KL", "GRM188R71H104KA93D"])
    #expect(find("low") == ["GRM188R71H104KA93D"])
    #expect(find("tag:rp2040") == ["Raspberry Pi Pico"])
    #expect(find("mfr:murata") == ["GRM188R71H104KA93D"])
    #expect(find("296-1395") == ["LM358DR"])   // a supplier's part number
    #expect(find("opamp texas") == ["LM358DR"])
}

@Test func facetsFilterAndCount() throws {
    var mine = Backup()
    var p = Backup.Part(id: "m1"); p.mpn = "RC0603FR-0710KL"; p.manufacturer = "Yageo"; p.category = "Passives/Resistors"; p.qty = 480
    p.params = PartParams(kind: "R", value: 10_000, tol: 0.01, pkg: "0603"); p.package = "0603"
    mine.parts = [p]
    let rows = mine.rows() + (try fixture().rows(source: "Sam"))
    let idx = FacetIndex(rows)
    let none = idx.result(PartQuery(""), FacetFilter())
    #expect(none.matches.count == 6)
    let passives = try #require(none.facets[.category]?.first { $0.key == "Passives" })
    #expect(passives.count == 3 && passives.children.map(\.label) == ["Capacitors", "Resistors"])
    #expect(passives.children.first { $0.label == "Resistors" }?.count == 2)
    #expect(none.facets[.source]?.map(\.label) == ["Mine", "Sam"])
    #expect(none.facets[.stock]?.map(\.key) == ["in", "low", "out"])
    #expect(none.facets[.location]?.last?.key == "")   // "None" last

    // A tree node includes its descendants; values in a facet OR; facets AND.
    var f = FacetFilter()
    f.toggle(.category, "Passives")
    var r = idx.result(PartQuery(""), f)
    #expect(r.matches.count == 3)
    // The category facet still counts as if nothing were chosen in it; others count within Passives.
    #expect(r.facets[.category]?.first { $0.key == "ICs" }?.count == 1)
    #expect(r.facets[.source]?.first { $0.key == "Sam" }?.count == 2)
    f.toggle(.source, "")
    r = idx.result(PartQuery(""), f)
    #expect(r.matches.map { rows[$0].id } == ["m1"])
    #expect(r.facets[.source]?.first { $0.key == "Sam" }?.count == 2)   // what choosing Sam would add
    f.toggle(.source, "Sam")
    #expect(idx.result(PartQuery(""), f).matches.count == 3)
    f.toggle(.category, "Boards")
    #expect(idx.result(PartQuery(""), f).matches.count == 4)
    // Search ANDs with facets.
    #expect(idx.result(PartQuery("10k"), f).matches.count == 2)
    #expect(idx.result(PartQuery("0603"), f).matches.map { rows[$0].id }.sorted() == ["m1", "p-sam-3"])

    // A chosen value with no rows left stays listed, with 0.
    var g = FacetFilter(); g.toggle(.manufacturer, "Nobody")
    let gr = idx.result(PartQuery(""), g)
    #expect(gr.matches.isEmpty && gr.facets[.manufacturer]?.contains { $0.key == "Nobody" && $0.count == 0 } == true)
    #expect(g.chips.map(\.key) == ["Nobody"])
    g.remove(.manufacturer, "Nobody")
    #expect(g.isEmpty)
}

@Test func facetKeys() throws {
    let rows = try fixture().rows(source: "Sam")
    let pico = try #require(rows.first { $0.id == "p-sam-4" })
    #expect(FacetKind.stock.keys(pico) == ["out"])
    #expect(FacetKind.tags.keys(pico) == ["rp2040", "lend-ok"])
    #expect(FacetKind.package.keys(pico) == [""])
    let cap = try #require(rows.first { $0.id == "p-sam-3" })
    #expect(FacetKind.category.keys(cap) == ["Passives", "Passives › Capacitors", "Passives › Capacitors › Ceramic"])
    #expect(FacetKind.kind.label("C") == "Capacitors" && FacetKind.source.label("") == "Mine")
}

@Test func borrowRequest() throws {
    let lm = try #require(try fixture().rows(source: "Sam").first { $0.mpn == "LM358DR" })
    #expect(lm.borrowRequest(2) == "Could I borrow 2 × LM358DR (IC OPAMP GP 2 CIRCUIT 8SOIC)? Your inventory has it in Workbench.")
}
