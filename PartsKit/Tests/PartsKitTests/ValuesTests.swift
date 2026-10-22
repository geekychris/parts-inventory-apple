import Foundation
import Testing
@testable import PartsKit

// The same cases as the web tool's tests/tools/parts-inventory.test.js.

func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-12) -> Bool { a.map { abs($0 - b) <= eps } ?? false }

@Test func engineeringValues() {
    let V = Values.parse
    #expect(V("4k7")?.value == 4700); #expect(V("4k7")?.kind == "R")
    #expect(near(V("0.1uF")?.value, 1e-7)); #expect(V("0.1uF")?.kind == "C"); #expect(V("0.1uF")?.guessed == false)
    #expect(near(V("100n")?.value, 1e-7)); #expect(V("100n")?.kind == "C"); #expect(V("100n")?.guessed == true)
    #expect(near(V("2u2")?.value, 2.2e-6)); #expect(near(V("4n7")?.value, 4.7e-9)); #expect(near(V("22pF")?.value, 22e-12))
    #expect(V("4R7")?.value == 4.7); #expect(V("0R")?.value == 0); #expect(V("1k0")?.value == 1000); #expect(V("4k75")?.value == 4750)
    #expect(V("1M")?.value == 1e6); #expect(V("1Meg")?.value == 1e6); #expect(V("10kΩ")?.value == 1e4); #expect(V("10 kOhm")?.value == 1e4)
    #expect(near(V("10µH")?.value, 1e-5)); #expect(V("10µH")?.kind == "L")
    #expect(near(V("0.1UF")?.value, 1e-7, 1e-9)); #expect(near(V("100NF")?.value, 1e-7)); #expect(near(V("10UH")?.value, 1e-5))
    #expect(V("50V")?.value == 50); #expect(V("50V")?.kind == "V"); #expect(V("3V3")?.value == 3.3)
    #expect(V("1/4W")?.value == 0.25); #expect(V("1/4W")?.kind == "W"); #expect(V("250mW")?.value == 0.25)
    #expect(V("100")?.kind == nil, "a bare number has no kind")
    #expect(V("1N4148") == nil, "a diode name is not 1.4148 nF")
    #expect(V("2N2222") == nil)
    #expect(Values.tolerance("1%") == 0.01); #expect(Values.tolerance("±5%") == 0.05); #expect(Values.tolerance("0.1%") == 0.001); #expect(Values.tolerance("5") == nil)
    #expect(Values.format(4700, "Ω") == "4.7 kΩ"); #expect(Values.format(1e-7, "F") == "100 nF"); #expect(Values.format(2.2e-6, "F") == "2.2 µF")
    #expect(Values.same(4700, 4.7e3)); #expect(!Values.same(4700, 4750))
}

@Test func packagesNormalise() {
    let N = Values.normPackage
    for s in ["0603", "R_0603_1608Metric", "Resistor_SMD:R_0603_1608Metric", "C_0603_1608Metric_Pad1.08x0.95mm_HandSolder", "0603 (1608 Metric)", "1608M", "1608 metric"] {
        #expect(N(s) == "0603", "\(s)")
    }
    #expect(N("LED_SMD:LED_0805_2012Metric") == "0805")
    #expect(N("SOT23") == "SOT-23"); #expect(N("SOT-23-5") == "SOT-23-5"); #expect(N("8-SOIC") == "SOIC-8"); #expect(N("Package_SO:SOIC-8_3.9x4.9mm_P1.27mm") == "SOIC-8")
    #expect(N("TO-220-3") == "TO-220-3"); #expect(N("SOD123") == "SOD-123"); #expect(N("banana") == "")
}

@Test func paramsFromText() {
    #expect(Values.params(from: "RES 10K OHM 1% 1/10W 0603") == PartParams(kind: "R", value: 10000, tol: 0.01, power: 0.1, pkg: "0603"))
    let c = Values.params(from: "CAP CER 0.1UF 50V X7R 0603")
    #expect(c.kind == "C"); #expect(near(c.value, 1e-7)); #expect(c.voltage == 50); #expect(c.dielectric == "X7R"); #expect(c.pkg == "0603")
    #expect(Values.params(from: "IC OPAMP GP 2 CIRCUIT 8SOIC") == PartParams(kind: "U", pkg: "SOIC-8"))
    #expect(Values.params(from: "DIODE GEN PURP 100V 300MA SOD123") == PartParams(kind: "D", voltage: 100, pkg: "SOD-123"))
    let k = Values.params(from: "100n", kind: "C", footprint: "Capacitor_SMD:C_0603_1608Metric")
    #expect(k.kind == "C"); #expect(near(k.value, 1e-7)); #expect(k.pkg == "0603")
    #expect(Values.params(from: "4k7 1%", kind: "R", footprint: "Resistor_SMD:R_0805_2012Metric") == PartParams(kind: "R", value: 4700, tol: 0.01, pkg: "0805"))
    #expect(Values.params(from: "1N4148", kind: "D") == PartParams(kind: "D"))
    #expect(Values.kind(fromRef: "R12") == "R"); #expect(Values.kind(fromRef: "U1") == "U"); #expect(Values.kind(fromRef: "LED2") == "LED"); #expect(Values.kind(fromRef: "FB1") == "L")
    #expect(Values.summary(PartParams(kind: "R", value: 10000, tol: 0.01, power: 0.1, pkg: "0603")) == "10 kΩ ±1% 100 mW 0603")
}

@Test func queries() {
    let q = PartQuery("10k 0603 1%")
    #expect(q.value == 10000); #expect(q.kind == "R"); #expect(q.pkg == "0603"); #expect(q.tol == 0.01); #expect(q.text.isEmpty)
    #expect(q.matches(PartParams(kind: "R", value: 10000, tol: 0.01, pkg: "0603")))
    #expect(!q.matches(PartParams(kind: "R", value: 10000, tol: 0.05, pkg: "0603")), "tolerance must be at least as tight")
    #expect(!q.matches(PartParams(kind: "R", value: 10000, tol: 0.01, pkg: "0805")))
    let p = PartQuery("100n 16V cat:caps \"low noise\" low")
    #expect(near(p.value, 1e-7)); #expect(p.kindGuessed); #expect(p.voltage == 16); #expect(p.category == "caps"); #expect(p.text == ["low noise"]); #expect(p.lowOnly)
    #expect(p.matches(PartParams(kind: "C", value: 1e-7, voltage: 25)))
    #expect(!p.matches(PartParams(kind: "C", value: 1e-7, voltage: 10)))
    #expect(PartQuery("lm358").text == ["lm358"])
}

@Test func backupRoundTrip() throws {
    let json = """
    {"schema":"gw-parts-inventory","version":1,"settings":{"currency":"EUR"},
     "parts":[{"id":"p1","mpn":"RC0603FR-0710KL","qty":100,"locationId":"l2","params":{"kind":"R","value":10000,"pkg":"0603"},
               "suppliers":[{"supplier":"digikey","pn":"311-10.0KHRCT-ND","breaks":[{"qty":1,"unit":0.1}]},{"supplier":"","pn":"x"}],
               "prices":[{"at":1,"unit":0.01,"currency":"USD","qty":100}],"tags":["smd"],"created":5,"updated":6},
              {"id":"p1","mpn":"duplicate"},{"mpn":"no id"}],
     "locations":[{"id":"l1","name":"Cabinet"},{"id":"l2","parentId":"l1","name":"Drawer 3"},{"id":"l3","parentId":"gone","name":"Box"}],
     "projects":[{"id":"pr1","name":"Clock","lines":[{"refs":"R1 R2","qty":2,"value":"10k","partId":"missing"}],"reserved":{"p1":4,"zz":1}}],
     "history":[{"id":"h1","at":5,"partId":"p1","delta":100,"qtyAfter":100,"reason":"Order","lot":"L1"}]}
    """
    let (b, warnings) = try Backup.read(Data(json.utf8))
    #expect(b.parts.count == 1); #expect(b.parts[0].suppliers.count == 1); #expect(b.parts[0].params.value == 10000)
    #expect(b.locations.count == 3); #expect(b.locations[2].parentId == nil)
    #expect(b.projects[0].lines[0].refs == ["R1", "R2"]); #expect(b.projects[0].lines[0].partId == nil); #expect(b.projects[0].reserved == ["p1": 4])
    #expect(b.history[0].lot == "L1")
    #expect(warnings.contains { $0.contains("skipped") }); #expect(warnings.contains { $0.contains("cleared") })
    let again = try Backup.read(b.encoded()).backup
    #expect(again.parts[0].mpn == "RC0603FR-0710KL"); #expect(again.settings["currency"] == .string("EUR"))
    #expect(throws: Backup.ReadError.self) { try Backup.read(Data(#"{"schema":"other","version":1}"#.utf8)) }
    #expect(throws: Backup.ReadError.self) { try Backup.read(Data(#"{"schema":"gw-parts-inventory","version":9}"#.utf8)) }
}
