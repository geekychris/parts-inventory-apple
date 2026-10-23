import Foundation
import Testing
@testable import PartsKit

@Test func digiKeyOrderCSV() throws {
    let csv = """
    "Sales Order #: 87654321"
    Index,Quantity,Part Number,Manufacturer Part Number,Description,Customer Reference,Backorder,Unit Price,Extended Price
    1,10,296-1395-1-ND,LM358DR,"IC OPAMP GP 2 CIRCUIT 8SOIC",,0,$0.42000,$4.20
    2,"1,000",311-10.0KHRCT-ND,RC0603FR-0710KL,RES 10K OHM 1% 1/10W 0603,R12,0,$0.00350,$3.50
    ,,,,,,,Subtotal,$7.70
    """
    let o = try SupplierOrder.read(text: csv, fileName: "order.csv")
    #expect(o.supplier == "digikey")
    #expect(o.number == "87654321")
    #expect(o.currency == "USD")
    #expect(o.lines.count == 2)
    #expect(o.lines[0].spn == "296-1395-1-ND")
    #expect(o.lines[0].mpn == "LM358DR")
    #expect(o.lines[0].qty == 10)
    #expect(o.lines[0].unitPrice == 0.42)
    #expect(o.lines[1].qty == 1000)
    #expect(o.lines[1].customerReference == "R12")
}

@Test func mouserOrderAsHTMLExcel() throws {
    let html = """
    <html><body><p>Mouser Electronics Sales Order 271828182</p><table>
    <TR><TH>Line</TH><TH>Mouser No</TH><TH>Mfr. No</TH><TH>Manufacturer</TH><TH>Description</TH><TH>Order Qty.</TH><TH>Price (USD)</TH><TH>Ext.: (USD)</TH></TR>
    <tr><td>1</td><td>595-LM358DR</td><td><a href="#">LM358DR</a></td><td>Texas Instruments</td><td>Operational Amplifiers &amp; Comparators</td><td>25</td><td>$0.389</td><td>$9.73</td></tr>
    <tr><td>2</td><td>621-AMS1117-3.3</td><td>AMS1117-3.3</td><td>Diodes Incorporated</td><td>LDO Voltage Regulators</td><td>5</td><td>$0.52</td><td>$2.60</td></tr>
    </table></body></html>
    """
    let o = try SupplierOrder.read(Data(html.utf8), fileName: "OrderHistory.xls")
    #expect(o.supplier == "mouser")
    #expect(o.number == "271828182")
    #expect(o.lines.map(\.spn) == ["595-LM358DR", "621-AMS1117-3.3"])
    #expect(o.lines[0].mpn == "LM358DR")
    #expect(o.lines[0].manufacturer == "Texas Instruments")
    #expect(o.lines[0].description == "Operational Amplifiers & Comparators")
    #expect(o.lines[0].qty == 25)
    #expect(o.lines[0].unitPrice == 0.389)
}

@Test func pastedFromTheWebsiteIsTabSeparated() throws {
    let pasted = "Mouser #\tMfr. #\tManufacturer\tCustomer #\tDescription\tQty.\tUnit Price\n595-LM358DR\tLM358DR\tTexas Instruments\t\tOp Amps\t3\t$0.39\n"
    let o = try SupplierOrder.read(text: pasted)
    #expect(o.supplier == "mouser")
    #expect(o.lines.count == 1)
    #expect(o.lines[0].qty == 3)
}

@Test func lcscOrderAndGuessingTheSupplier() throws {
    let csv = "LCSC Part Number,Manufacture Part Number,Manufacturer,Package,Quantity,Unit Price($)\nC7950,LM358DR,TI,SOIC-8,20,0.0612\n"
    let o = try SupplierOrder.read(text: csv)
    #expect(o.supplier == "lcsc")
    #expect(o.lines[0].spn == "C7950")
    #expect(o.lines[0].unitPrice == 0.0612)
    #expect(SupplierOrder.supplierFromNumber("296-1395-1-ND") == "digikey")
    #expect(SupplierOrder.supplierFromNumber("595-LM358DR") == "mouser")
    #expect(SupplierOrder.supplierFromNumber("C7950") == "lcsc")
}

@Test func notAnOrderSaysWhy() {
    #expect(throws: SupplierOrder.ReadError.self) { try SupplierOrder.read(text: "Name,Colour\nApple,Red\n") }
    #expect(throws: SupplierOrder.ReadError.oldExcel) { try SupplierOrder.read(Data([0xD0, 0xCF, 0x11, 0xE0, 0, 0])) }
}

@Test func numbersInTheirManyForms() {
    #expect(SupplierOrder.number("$1,234.50") == 1234.5)
    #expect(SupplierOrder.number("0,42 €") == 0.42)
    #expect(SupplierOrder.number("1,000") == 1000)
    #expect(SupplierOrder.number("") == nil)
    #expect(SupplierOrder.orderNumber(in: "digikey-order-87654321.csv") == "87654321")
    #expect(SupplierOrder.orderNumber(in: "Order Qty. 25") == nil)
}

/// An .xlsx from the app's own Excel writer reads back, stored and deflated.
@Test func xlsxOrders() throws {
    let table = ExportTable(header: ["Digi-Key Part Number", "Manufacturer Part Number", "Quantity", "Unit Price"],
                            rows: [[.text("296-1395-1-ND"), .text("LM358DR"), .number(10), .number(0.42)]])
    let stored = XLSX.data(table)
    let o = try SupplierOrder.read(stored, fileName: "digikey.xlsx")
    #expect(o.lines.first?.mpn == "LM358DR")
    #expect(o.lines.first?.qty == 10)

    // Re-zip with deflate, as Excel writes them.
    let dir = FileManager.default.temporaryDirectory.appending(path: "xlsx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try stored.write(to: dir.appending(path: "in.xlsx"))
    func run(_ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args; p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice; try p.run(); p.waitUntilExit()
    }
    try run(["unzip", "-q", "in.xlsx", "-d", "x"])
    let x = dir.appending(path: "x")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); p.arguments = ["-q", "-r", "-9", "../out.xlsx", "."]
    p.currentDirectoryURL = x; try p.run(); p.waitUntilExit()
    let deflated = try Data(contentsOf: dir.appending(path: "out.xlsx"))
    let o2 = try SupplierOrder.read(deflated)
    #expect(o2.lines == o.lines.map { var l = $0; l.supplier = "digikey"; return l })
}
