import Testing
@testable import PartsKit

// ECIA EIGP 114 format 06 payloads, as in the web tool's tests.
let DK = "[)>\u{1e}06\u{1d}P296-LM358BIDDFRCT-ND\u{1d}1PLM358BIDDFR\u{1d}K\u{1d}1K72991337\u{1d}10K85781337\u{1d}11K1\u{1d}4LPH\u{1d}Q10\u{1d}11ZPICK\u{1d}12Z15221337\u{1d}13Z361337\u{1d}20Z" + String(repeating: "0", count: 60) + "\u{1e}\u{04}"
let DK30P = "[)>\u{1e}06\u{1d}PMY-ACME-R10K\u{1d}1PRC0603FR-0710KL\u{1d}30P311-10.0KHRCT-ND\u{1d}KPO-2026-117\u{1d}1K81234567\u{1d}10K98765432\u{1d}9D2331\u{1d}1TL230815A\u{1d}11K1\u{1d}4LTW\u{1d}Q100\u{1d}11ZPICK\u{1d}12Z1234567\u{1d}13Z765432\u{1d}20Z0000\u{1e}\u{04}"
let MOUSER = "[)>\u{1e}06\u{1d}KP0-1337\u{1d}14K011\u{1d}1PMC34063ADR\u{1d}Q3\u{1d}11K073121337\u{1d}4LMX\u{1d}1VTI\u{1e}\u{04}"

@Test func digikeyLabel() {
    let r = BagLabels.parse(DK)
    #expect(r.kind == .ecia); #expect(r.supplier == "digikey")
    #expect([r.spn, r.mpn, r.salesOrder, r.invoice, r.countryOfOrigin, r.po] == ["296-LM358BIDDFRCT-ND", "LM358BIDDFR", "72991337", "85781337", "PH", ""])
    #expect(r.qty == 10)
    #expect(r.fields.first { $0.di == "20Z" }?.name == "Padding")
}

@Test func digikey30PLabel() {
    let r = BagLabels.parse(DK30P)
    #expect(r.supplier == "digikey")
    #expect([r.spn, r.customerPn, r.mpn, r.po, r.dateCode, r.lot, r.countryOfOrigin] == ["311-10.0KHRCT-ND", "MY-ACME-R10K", "RC0603FR-0710KL", "PO-2026-117", "2331", "L230815A", "TW"])
    #expect(r.qty == 100)
}

@Test func mouserLabel() {
    let r = BagLabels.parse(MOUSER)
    #expect(r.supplier == "mouser")
    #expect([r.mpn, r.po, r.manufacturer, r.countryOfOrigin, r.invoice, r.spn] == ["MC34063ADR", "P0-1337", "TI", "MX", "073121337", ""])
    #expect(r.qty == 3)
}

@Test func scannedTextVariants() {
    let pictures = DK.replacingOccurrences(of: "\u{1d}", with: "␝").replacingOccurrences(of: "\u{1e}", with: "␞").replacingOccurrences(of: "\u{04}", with: "␄")
    #expect(BagLabels.parse(pictures).spn == "296-LM358BIDDFRCT-ND")
    let braces = MOUSER.replacingOccurrences(of: "\u{1d}", with: "{GS}").replacingOccurrences(of: "\u{1e}", with: "{RS}").replacingOccurrences(of: "\u{04}", with: "{EOT}")
    #expect(BagLabels.parse(braces).mpn == "MC34063ADR")
    let r = BagLabels.parse("[)>\u{1e}06\u{1d}1PNE555P\u{1d}Q25\u{1d}1VTexas Instruments")
    #expect(r.mpn == "NE555P"); #expect(r.qty == 25); #expect(r.manufacturer == "Texas Instruments"); #expect(r.supplier == "mouser")
    #expect(BagLabels.parse("[)>\u{1e}06\u{1d}Q12\u{1d}1PABC\r\n").qty == 12)
}

@Test func lcscAndPlain() {
    let r = BagLabels.parse("{pbn:PICK2309150012,on:SO2309150012,pc:C25804,pm:0603WAF1002T5E,qty:100,mc:,cc:1,pdi:91523110,hp:null,wc:ZH}")
    #expect(r.kind == .lcsc); #expect(r.spn == "C25804"); #expect(r.mpn == "0603WAF1002T5E"); #expect(r.qty == 100); #expect(r.salesOrder == "SO2309150012")
    #expect(BagLabels.parse("296-6501-1-ND").supplier == "digikey")
    #expect(BagLabels.parse("595-NE555P").supplier == "mouser")
    #expect(BagLabels.parse("C1591").supplier == "lcsc")
    #expect(BagLabels.parse("250").qty == 250)
    #expect(BagLabels.parse("LM358DR").mpn == "LM358DR")
}
