import Foundation
import Testing
@testable import PartsKit

// The same cases as the web tool's tests/tools/parts-identify.test.js.

func w(_ text: String, _ conf: Double = 90, _ line: Int = 0) -> OCRWord { OCRWord(text: text, conf: conf, line: line) }
func top(_ words: [OCRWord], look: [LookScore] = []) -> Candidate? { Identify.rank(tokens: Identify.tokens(words), look: look).first }
func top(_ text: String) -> Candidate? { top(Identify.words(text)) }
func entryId(_ c: Candidate?) -> String? { if case .catalog(let e)? = c?.source { return e.id }; return nil }
let cat = Catalog.shared
func lookOf(_ id: String) -> String { cat.entry(id)?.look ?? cat.genericKind(id)!.look }
func genericId(_ label: String) -> String { cat.generic.first { $0.look == label }!.id }

@Test func catalogIsWellFormed() {
    var ids = Set<String>()
    for e in cat.entries {
        #expect(!ids.contains(e.id)); ids.insert(e.id)
        #expect(["ic", "module", "board", "discrete"].contains(e.kind))
        #expect(!(e.marks ?? []).isEmpty || e.look != nil, "\(e.id) needs marks or a look")
        if let ds = e.ds { #expect(ds.hasPrefix("https://")) }
    }
    #expect(cat.generic.count >= 40)
}

@Test func normalising() {
    #expect(Identify.normTok(" atmega328p-pu, ") == "ATMEGA328P-PU")
    #expect(Identify.squash("ESP32-WROOM-32") == "ESP32WROOM32")
    #expect(Identify.canon("LM3S8") == Identify.canon("LM358"))
    #expect(Identify.canon("ATMEGA32BP") == Identify.canon("ATMEGA328P"))
    #expect(Identify.lev("kitten", "sitting") == 3)
}

@Test func markMatching() {
    #expect(Identify.markScore("ATMEGA328P", "ATMEGA328P")?.how == "exact")
    #expect(Identify.markScore("ATMEGA328P-PU", "ATMEGA328P")?.how == "with a suffix")
    #expect(Identify.markScore("SN74HC595N", "74HC595")?.how == "inside a longer number")
    #expect(Identify.markScore("LM3S8N", "LM358")?.how == "allowing for OCR look-alikes")
    #expect(Identify.markScore("LM3580", "LM358") == nil)
    #expect(Identify.markScore("555", "555")?.score == 0.7)
    #expect(Identify.markScore("5550", "555") == nil)
    #expect(Identify.markScore("ATMEGA328P", "ATMEGA32U4") == nil)
}

@Test func splitMarkingsAndMaker() {
    let r = top([w("ATMEL", 90, 0), w("ATMEGA", 80, 1), w("328P-AU", 80, 1), w("1932", 88, 2)])
    #expect(entryId(r) == "atmega328p")
    #expect((r?.score ?? 0) > 0.8)
    #expect(r?.reasons.first?.contains("maker’s name") == true)
    let plain = top([w("ATMEGA328P", 90)])!, withMfr = top([w("ATMEGA328P", 90), w("ATMEL", 90, 1)])!
    #expect(withMfr.score > plain.score)
}

@Test func commonParts() {
    let cases = ["ESP32-WROOM-32E": "esp32-wroom-32", "SN74HC595N": "74hc595", "BOGI": "ads1115", "AMS1117 3.3": "ams1117", "CH340G": "ch340",
                 "NE555P": "ne555", "ULN2003AN": "uln2003", "RP2-B2": "rp2040", "ARDUINO UNO": "arduino-uno", "L7805CV": "l7805", "MPU-6050": "mpu6050", "DS3231SN": "ds3231"]
    for (text, id) in cases { #expect(entryId(top(text)) == id, "\(text)") }
}

@Test func unknownNumbers() {
    #expect(Identify.partNumberLikeness("XC6206P332MR") > 0.5)
    #expect(Identify.partNumberLikeness("1932") == 0)
    #expect(Identify.partNumberLikeness("GND") == 0)
    #expect(Identify.partNumberLikeness("REV1.2") == 0)
    #expect(Identify.partNumberLikeness("5V") == 0)
    let r = Identify.rank(tokens: Identify.tokens(Identify.words("XC6206P332MR\n2209")))
    #expect(r.count == 1)
    #expect(r.first?.source == .unknown("XC6206P332MR"))
    let esp = Identify.rank(tokens: Identify.tokens(Identify.words("ESP32-WROOM-32E")))
    #expect(!esp.contains { if case .unknown = $0.source { true } else { false } })
    #expect(Identify.unknownNumbers(Identify.tokens(Identify.words("FCC ID 2AC7Z-ESPWROOM32E")), covered: []).count == 1)
}

@Test func inventoryWins() {
    let parts = [InventoryRef(id: "p1", mpn: "RC0603FR-0710KL", supplierPNs: ["311-10.0KHRCT-ND"])]
    let r = Identify.rank(tokens: Identify.tokens(Identify.words("RC0603FR-0710KL")), inventory: parts)
    #expect(r.first?.source == .inventory(parts[0]))
    #expect(!r.contains { if case .unknown = $0.source { true } else { false } })
    #expect(Identify.rank(tokens: Identify.tokens(Identify.words("311-10.0KHRCT-ND")), inventory: parts).first?.source == .inventory(parts[0]))
    // a catalog part you already have: your part first
    let mine = [InventoryRef(id: "p2", mpn: "ATmega328P-PU")]
    #expect(Identify.rank(tokens: Identify.tokens(Identify.words("ATMEGA328P-PU")), inventory: mine).first?.source == .inventory(mine[0]))
}

@Test func looks() {
    let look = [LookScore(ref: "hc-sr04", score: 0.7), LookScore(ref: "g-pcb", score: 0.25)]
    let r = Identify.rank(tokens: [], look: look)
    #expect(entryId(r.first) == "hc-sr04")
    #expect(r[0].score <= 0.75)
    if case .generic = r[1].source {} else { Issue.record("second should be generic") }
    let noise = [LookScore(ref: "wemos-d1-mini", score: 0.18), LookScore(ref: "relay-module", score: 0.09)]
    #expect(Identify.rank(tokens: Identify.tokens(Identify.words("ATMEGA328P-PU")), look: noise).map(entryId) == ["atmega328p"])
    #expect(Identify.rank(tokens: [], look: noise).map(entryId) == ["wemos-d1-mini"])
    let both = Identify.rank(tokens: Identify.tokens(Identify.words("HC-SR04")), look: look)[0]
    #expect(entryId(both) == "hc-sr04"); #expect(both.reasons.count == 2)
}

@Test func modeLeans() {
    let toks = Identify.tokens(Identify.words("ESP32-DEVKITC\nESP32-D0WD-V3"))
    #expect(entryId(Identify.rank(tokens: toks, mode: .chip).first) == "esp32")
    #expect(entryId(Identify.rank(tokens: toks, mode: .board).first) == "esp32-devkitc")
}

@Test func drafts() {
    let at = Date(timeIntervalSince1970: 1_792_540_800) // 2026-10-21
    let f = Identify.draft(top("ATMEGA328P-PU")!, ocrText: "ATMEL\nATMEGA328P-PU\n1932", at: at)
    #expect(f.mpn == "ATmega328P"); #expect(f.manufacturer == "Microchip (Atmel)"); #expect(f.category == "ICs/Microcontrollers"); #expect(f.package == "DIP-28")
    #expect(f.datasheet.hasPrefix("https://ww1.microchip.com/")); #expect(f.params == PartParams(kind: "U")); #expect(f.tags == ["identified", "ic"])
    #expect(f.notes.contains("2026-10-21")); #expect(f.notes.contains("ATMEL ATMEGA328P-PU 1932"))
    let b = Identify.draft(top("ARDUINO NANO")!, at: at)
    #expect(b.package == ""); #expect(b.description.hasPrefix("Arduino Nano — "))
    let u = Identify.draft(Identify.rank(tokens: Identify.tokens(Identify.words("XC6206P332MR")))[0], at: at)
    #expect(u.mpn == "XC6206P332MR"); #expect(u.datasheet == "")
    for l in Identify.searchLinks("XC6206P332MR") { #expect(l.url.absoluteString.hasPrefix("https://") && l.url.absoluteString.contains("XC6206P332MR")) }
    #expect(Identify.searchLinks("x").contains { $0.id == "ebay" })
}

@Test func searchingTheList() {
    #expect(cat.search("ESP32 devkitc").first?.id == "esp32-devkitc")
    #expect(cat.search("motor driver").count >= 4)
    #expect(cat.search("BOGI").first?.id == "ads1115")
    #expect(cat.search("").isEmpty)
}

@Test func looksInTwoSteps() {
    let pot = [LookScore(ref: genericId("a trimmer potentiometer"), score: 0.6), LookScore(ref: genericId("a potentiometer"), score: 0.29),
               LookScore(ref: genericId("a toggle switch"), score: 0.06), LookScore(ref: genericId("a circuit board module"), score: 0.05)]
    #expect(Identify.boardShare(pot) < 0.15)
    let r = Identify.rank(tokens: [], look: Identify.combine(kinds: pot, boards: []))
    #expect(r.map { if case .generic(let g) = $0.source { g.id } else { "" } } == ["g-trimpot", "g-pot"])
    #expect(r[0].score >= 0.5)
    let f = Identify.draft(r[0])
    #expect(f.description == "Trimmer potentiometer"); #expect(f.category == "Passives/Potentiometers")
    let kinds = [LookScore(ref: genericId("a sensor breakout board"), score: 0.5), LookScore(ref: genericId("a circuit board module"), score: 0.3), LookScore(ref: genericId("a relay"), score: 0.2)]
    let boards = [LookScore(ref: "hc-sr04", score: 0.9), LookScore(ref: "dht22", score: 0.1)]
    let both = Identify.combine(kinds: kinds, boards: boards)
    #expect(String(format: "%.2f", both.first { $0.ref == "hc-sr04" }!.score) == "0.72")
    #expect(entryId(Identify.rank(tokens: [], look: both).first) == "hc-sr04")
}
