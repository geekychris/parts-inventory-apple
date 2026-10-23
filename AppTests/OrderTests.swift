import Foundation
import SwiftData
import Testing
import PartsKit
@testable import Parts_Inventory

/// An order's lines go into stock as scanned bags would: parts you have get more, the rest are made.
@MainActor
@Test func receivingAnOrder() throws {
    let schema = Schema(Schema1.models)
    let ctx = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
    DebugLaunch.demo(ctx)
    try ctx.save()
    let parts = { (try? ctx.fetch(FetchDescriptor<Part>())) ?? [] }
    let lm358 = try #require(parts().first { $0.mpn == "LM358DR" })
    let had = lm358.qty

    let order = try SupplierOrder.read(text: """
    Mouser #\tMfr. #\tManufacturer\tDescription\tOrder Qty.\tPrice (USD)
    595-LM358DR\tLM358DR\tTexas Instruments\tOp Amps\t10\t$0.39
    511-L7805CV\tL7805CV\tSTMicroelectronics\tLinear Voltage Regulators 5V 1.5A\t3\t$0.71
    """)
    #expect(Inventory.match(order.lines[0], in: ctx)?.uid == lm358.uid)
    #expect(Inventory.match(order.lines[1], in: ctx) == nil)

    let bin = try #require((try ctx.fetch(FetchDescriptor<StorageLocation>())).first { $0.name == "Bin 3" })
    let r = Inventory.receive(order, lines: order.lines, location: bin, in: ctx)
    #expect(r.added == 1 && r.updated == 1)
    #expect(lm358.qty == had + 10)
    #expect(lm358.suppliers.contains { $0.supplier == "mouser" && $0.pn == "595-LM358DR" })
    #expect(lm358.prices.last?.unit == 0.39)

    let reg = try #require(parts().first { $0.mpn == "L7805CV" })
    #expect(reg.qty == 3)
    #expect(reg.location?.uid == bin.uid)
    #expect(reg.partDescription == "Linear Voltage Regulators 5V 1.5A")
    #expect(reg.manufacturer == "STMicroelectronics")
    #expect(reg.tags == ["ordered"])
    #expect(reg.prices.first?.currency == "USD")
    #expect(reg.history?.first?.reason.hasPrefix("Order") == true)
}
