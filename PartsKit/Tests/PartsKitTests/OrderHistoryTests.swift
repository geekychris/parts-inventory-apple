import Foundation
import Testing
@testable import PartsKit

@Test func digiKeyOrderList() throws {
    let json = """
    {"TotalOrders": 1, "Orders": [{"OrderNumber": 55501234, "DateEntered": "2026-09-14T17:03:22Z", "Currency": "USD",
      "EntireOrderStatus": {"OrderStatus": "Shipped", "ShortDescription": "Shipped"},
      "SalesOrders": [{"SalesOrderId": 87654321, "OrderNumber": 55501234, "TotalPrice": 12.95, "Currency": "USD",
        "DateEntered": "2026-09-14T17:03:22.123Z", "Status": {"SalesOrderStatus": "Shipped", "ShortDescription": "Shipped"},
        "LineItems": [
          {"DigiKeyProductNumber": "296-1395-1-ND", "ManufacturerProductNumber": "LM358DR", "Description": "IC OPAMP GP 2 CIRCUIT 8SOIC",
           "QuantityOrdered": 10, "QuantityShipped": 10, "UnitPrice": 0.42, "CustomerReference": "U3"},
          {"DigiKeyProductNumber": "311-10.0KHRCT-ND", "ManufacturerProductNumber": "RC0603FR-0710KL", "Description": "RES 10K OHM 1% 1/10W 0603",
           "QuantityOrdered": 100, "QuantityShipped": 0, "UnitPrice": 0.0035}
        ]}]}]}
    """
    let r = try DigiKeyAPI.parseOrders(Data(json.utf8))
    #expect(r.total == 1)
    #expect(r.orders.count == 1)
    let s = try #require(r.orders.first)
    #expect(s.number == "87654321")
    #expect(s.webNumber == "55501234")
    #expect(s.status == "Shipped")
    #expect(s.total == 12.95)
    #expect(s.date != nil)
    let o = try #require(s.order)
    #expect(o.number == "87654321")
    #expect(o.supplier == "digikey")
    #expect(o.lines.count == 2)
    #expect(o.lines[0].spn == "296-1395-1-ND")
    #expect(o.lines[0].mpn == "LM358DR")
    #expect(o.lines[0].qty == 10)
    #expect(o.lines[0].customerReference == "U3")
    #expect(o.lines[1].qty == 100)   // not shipped yet: what was ordered
}

@Test func digiKeyOrderProblem() {
    let json = #"{"type": "x", "title": "Unauthorized", "status": 401, "detail": "Invalid account"}"#
    #expect(throws: SupplierError.self) { try DigiKeyAPI.parseOrders(Data(json.utf8)) }
}

@Test func mouserOrderHistory() throws {
    let json = """
    {"Errors": [], "NumberOfOrders": 2, "OrderHistoryItems": [
      {"DateCreated": "3/2/2026 9:15:00 AM", "SalesOrderNumber": "271828182", "WebOrderNumber": "314159", "OrderStatusDisplay": "Shipped"},
      {"DateCreated": "9/20/2026 2:40:10 PM", "SalesOrderNumber": "271828999", "WebOrderNumber": "314200", "OrderStatusDisplay": "In Process"}
    ]}
    """
    let orders = try MouserAPI.parseOrderHistory(Data(json.utf8))
    #expect(orders.map(\.number) == ["271828999", "271828182"])   // newest first
    #expect(orders[0].status == "In Process")
    #expect(orders[1].webNumber == "314159")
    #expect(orders[1].order == nil)
}

@Test func mouserOrderDetail() throws {
    let json = """
    {"SalesOrderId": "271828182", "CurrencyCode": "USD", "OrderLines": [
      {"Quantity": 25, "UnitPrice": 0.389, "ProductInfo": {"MouserPartNumber": "595-LM358DR", "ManufacturerName": "Texas Instruments",
       "ManufacturerPartNumber": "LM358DR", "PartDescription": "Operational Amplifiers - Op Amps Dual", "CustomerPartNumber": ""}},
      {"Quantity": 1, "UnitPrice": 5, "ProductInfo": {"MouserPartNumber": "N/A", "ManufacturerPartNumber": "", "PartDescription": "Shipping"}}
    ]}
    """
    let o = try MouserAPI.parseOrderDetail(Data(json.utf8), number: "271828182")
    #expect(o.number == "271828182")
    #expect(o.currency == "USD")
    #expect(o.lines.count == 1)
    #expect(o.lines[0].spn == "595-LM358DR")
    #expect(o.lines[0].manufacturer == "Texas Instruments")
    #expect(o.lines[0].qty == 25)
    #expect(o.lines[0].unitPrice == 0.389)
}

@Test func mouserOrderKeyRefused() {
    let json = #"{"Errors": [{"Code": "Invalid", "Message": "Invalid unique identifier."}], "OrderHistoryItems": null}"#
    #expect(throws: SupplierError.self) { try MouserAPI.parseOrderHistory(Data(json.utf8)) }
}

@Test func orderDates() {
    #expect(orderDate("2026-09-14T17:03:22Z") != nil)
    #expect(orderDate("2026-09-14T17:03:22.5") != nil)
    #expect(orderDate("3/2/2026 9:15:00 AM") != nil)
    #expect(orderDate("") == nil)
}
