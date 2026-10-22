import Foundation
import Testing
@testable import PartsKit

private func product(_ supplier: String, _ mpn: String, _ maker: String, spn: String = "", stock: Int? = 100) -> SupplierProduct {
    var p = SupplierProduct(supplier: supplier)
    p.mpn = mpn; p.manufacturer = maker; p.spn = spn.isEmpty ? "\(supplier)-\(mpn)" : spn; p.stock = stock
    return p
}

@Test func batchKeysAndMakers() {
    #expect(BatchMatch.key("atmega328p-pu") == "ATMEGA328PPU")
    #expect(BatchMatch.makerKey("Microchip Technology") == "MICROCHIP")
    #expect(BatchMatch.makerKey("Atmel") == "MICROCHIP")
    #expect(BatchMatch.makerKey("Texas Instruments") == "TEXAS")
    #expect(BatchMatch.makerKey("ON Semiconductor") == BatchMatch.makerKey("onsemi"))
}

@Test func batchQueriesPreferTheLabelThenCandidates() {
    var label = BagLabel()
    label.mpn = "LM358DR"; label.spn = "296-1395-1-ND"
    let cands = [Candidate(id: "u:X", source: .unknown("LM358DR"), score: 0.4, reasons: []),
                 Candidate(id: "u:Y", source: .unknown("NE555P"), score: 0.3, reasons: [])]
    #expect(BatchMatch.queries(label: label, candidates: cands) == ["LM358DR", "296-1395-1-ND"])
    #expect(BatchMatch.queries(label: nil, candidates: cands) == ["LM358DR", "NE555P"])
    #expect(BatchMatch.queries(label: nil, candidates: [Candidate(id: "g", source: .unknown("AB"), score: 0.2, reasons: [])]).isEmpty)
}

@Test func batchRankPutsTheNumberReadFirstThenStock() {
    let list = [product("digikey", "ATMEGA328P-PU DIP", "Microchip", stock: 0),
                product("digikey", "ATMEGA328P-AU", "Microchip"),
                product("mouser", "ATMEGA328P-PU", "Microchip", stock: 0),
                product("digikey", "ATMEGA328P-PU", "Microchip")]
    let ranked = BatchMatch.rank(list, ocrText: "ATMEL\nATMEGA328P-PU\n1932", queries: ["ATMEGA328P-PU"])
    #expect(ranked.prefix(2).map(\.supplier) == ["digikey", "mouser"])
    #expect(ranked.prefix(2).allSatisfy { $0.mpn == "ATMEGA328P-PU" })
    #expect(BatchMatch.isSure(ranked, ocrText: "ATMEL\nATMEGA328P-PU\n1932", queries: ["ATMEGA328P-PU"]))
}

@Test func batchNotSureWhenTwoMakersAndNeitherIsPrinted() {
    let list = [product("digikey", "LM358DR", "Texas Instruments"), product("digikey", "LM358DR", "Rohm Semiconductor")]
    let ranked = BatchMatch.rank(list, ocrText: "LM358DR", queries: ["LM358DR"])
    #expect(!BatchMatch.isSure(ranked, ocrText: "LM358DR", queries: ["LM358DR"]))
    // The maker printed on the part settles it, and goes first.
    let printed = BatchMatch.rank(list.reversed(), ocrText: "TI LM358DR", queries: ["LM358DR"])
    #expect(printed.first?.manufacturer == "Texas Instruments")
    #expect(BatchMatch.isSure(printed, ocrText: "TI LM358DR", queries: ["LM358DR"]))
}

@Test func batchNotSureWithoutAnExactReading() {
    // Looked up "LM358" (a query, not read exactly as the listing's number): ask.
    let list = [product("mouser", "LM358DR", "Texas Instruments")]
    let ranked = BatchMatch.rank(list, ocrText: "LM358", queries: ["LM358"])
    #expect(!BatchMatch.isSure(ranked, ocrText: "LM358", queries: ["LM358"]))
    #expect(!BatchMatch.isSure([], ocrText: "LM358", queries: ["LM358"]))
}

@Test func batchLabelIsExact() {
    var label = BagLabel()
    label.spn = "296-1395-1-ND"
    let list = [product("digikey", "LM358DR", "Texas Instruments", spn: "296-1395-1-ND"), product("digikey", "LM358DR", "Rohm")]
    let ranked = BatchMatch.rank(list, ocrText: "", label: label, queries: ["296-1395-1-ND"])
    #expect(ranked.first?.spn == "296-1395-1-ND")
    #expect(BatchMatch.isSure(ranked, ocrText: "", label: label, queries: ["296-1395-1-ND"]))
}

@Test func batchPartnerIsTheSamePartAtTheOtherSupplier() {
    let dk = product("digikey", "RC0603FR-0710KL", "YAGEO", stock: 0)
    let list = [dk, product("mouser", "RC0603FR-0710KL", "Yageo", stock: 3_207_614), product("mouser", "RC0603FR-0710KL", "Other")]
    #expect(BatchMatch.partner(of: dk, in: list)?.stock == 3_207_614)
    #expect(BatchMatch.partner(of: product("mouser", "X1", "A"), in: list) == nil)
}
