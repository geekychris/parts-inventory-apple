import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An order in a supplier's order history, as Digi-Key's Order Status API or Mouser's Order History API
/// lists it.
public struct OrderSummary: Sendable, Identifiable, Equatable {
    /// "digikey" or "mouser".
    public var supplier: String
    /// The sales order number: the one printed on the bags and the packing list.
    public var number: String
    public var webNumber = ""
    public var date: Date?
    public var status = ""
    public var total: Double?
    public var currency: String?
    /// The lines, when the list came with them (Digi-Key's does; Mouser's are fetched per order).
    public var order: SupplierOrder?

    public init(supplier: String, number: String) { self.supplier = supplier; self.number = number }

    public var id: String { "\(supplier):\(number)" }
    public var supplierName: String { Supplier.named(supplier)?.name ?? supplier }
}

/// Dates as the order APIs write them: ISO 8601 with or without a zone or fraction, or Mouser's "1/30/2019 3:04:05 PM".
func orderDate(_ v: Any?) -> Date? {
    let s = str(v)
    guard !s.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    for o: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
        iso.formatOptions = o
        if let d = iso.date(from: s) { return d }
    }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "M/d/yyyy h:mm:ss a", "M/d/yyyy H:mm:ss", "M/d/yyyy", "yyyy-MM-dd"] {
        f.dateFormat = format
        if let d = f.date(from: s) { return d }
    }
    return nil
}

// MARK: - Digi-Key

extension DigiKeyAPI {
    /// `GET /orderstatus/v4/orders` → `{ "TotalOrders": n, "Orders": [{ "OrderNumber", "SalesOrders": […] }] }`.
    /// One summary per sales order, lines included. Returns the orders and Digi-Key's total.
    public static func parseOrders(_ data: Data) throws -> (orders: [OrderSummary], total: Int) {
        guard let root = object(data) as? JSON else { throw SupplierError("digikey", "Digi-Key sent something that isn’t JSON.") }
        if let e = problem(root) { throw e }
        var out: [OrderSummary] = []
        for o in (root["Orders"] as? [JSON]) ?? [] {
            let status = str((o["EntireOrderStatus"] as? JSON)?["ShortDescription"])
            for so in (o["SalesOrders"] as? [JSON]) ?? [] {
                if let s = salesOrder(so, fallbackStatus: status, fallbackDate: o["DateEntered"], fallbackCurrency: o["Currency"]) { out.append(s) }
            }
        }
        return (out, (root["TotalOrders"] as? Int) ?? out.count)
    }

    /// `GET /orderstatus/v4/salesorder/{id}` → one sales order.
    public static func parseSalesOrder(_ data: Data) throws -> OrderSummary? {
        guard let root = object(data) as? JSON else { throw SupplierError("digikey", "Digi-Key sent something that isn’t JSON.") }
        if let e = problem(root) { throw e }
        return salesOrder(root, fallbackStatus: "", fallbackDate: nil, fallbackCurrency: nil)
    }

    static func salesOrder(_ so: JSON, fallbackStatus: String, fallbackDate: Any?, fallbackCurrency: Any?) -> OrderSummary? {
        let number = str(so["SalesOrderId"])
        guard !number.isEmpty else { return nil }
        var s = OrderSummary(supplier: "digikey", number: number)
        s.webNumber = str(so["OrderNumber"])
        s.date = orderDate(so["DateEntered"]) ?? orderDate(fallbackDate)
        let st = so["Status"] as? JSON
        s.status = [str(st?["ShortDescription"]), str(st?["SalesOrderStatus"]), fallbackStatus].first { !$0.isEmpty } ?? ""
        s.total = num(so["TotalPrice"])
        let cur = str(so["Currency"]).isEmpty ? str(fallbackCurrency) : str(so["Currency"])
        s.currency = cur.isEmpty ? nil : cur
        var order = SupplierOrder(supplier: "digikey")
        order.number = number
        order.currency = s.currency
        for (i, li) in ((so["LineItems"] as? [JSON]) ?? []).enumerated() {
            var l = SupplierOrder.Line(id: i, supplier: "digikey")
            l.spn = str(li["DigiKeyProductNumber"])
            l.mpn = str(li["ManufacturerProductNumber"])
            l.description = str(li["Description"])
            // What arrived; an order that hasn't shipped yet shows what was ordered.
            let shipped = Int(num(li["QuantityShipped"]) ?? 0), ordered = Int(num(li["QuantityOrdered"]) ?? 0)
            l.qty = shipped > 0 ? shipped : ordered
            l.unitPrice = num(li["UnitPrice"])
            l.customerReference = str(li["CustomerReference"])
            if !l.spn.isEmpty || !l.mpn.isEmpty { order.lines.append(l) }
        }
        s.order = order
        return s
    }
}

extension DigiKeyClient {
    /// The sales orders placed since `since` (newest first), with their lines. Uses the Order Status API with
    /// the app's own sign-in, which needs the customer account number.
    public func orders(accountID: String, since: Date, until: Date = .now) async throws -> [OrderSummary] {
        let account = accountID.filter(\.isNumber)
        guard !account.isEmpty else {
            throw SupplierError("digikey", "Add your Digi-Key account number in Settings to see your orders (it's on digikey.com › My Account).")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        var all: [OrderSummary] = [], page = 1
        while page <= 40 {
            let path = "/orderstatus/v4/orders?shared=false&startDate=\(f.string(from: since))&endDate=\(f.string(from: until))&pageNumber=\(page)&pageSize=25"
            let data: Data
            do {
                data = try await call("GET", path, headers: ["X-DIGIKEY-Account-Id": account])
            } catch let e as SupplierError where e.status == 401 || e.status == 403 {
                throw SupplierError("digikey", "Digi-Key wouldn't list the orders (\(e.message)). Check that your app at developer.digikey.com is also subscribed to Order Status, and the account number in Settings.", status: e.status)
            }
            let r = try DigiKeyAPI.parseOrders(data)
            all += r.orders
            if r.orders.isEmpty || all.count >= r.total { break }
            page += 1
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

// MARK: - Mouser

extension MouserAPI {
    /// `GET /orderhistory/ByDateFilter` → `{ "Errors": […], "OrderHistoryItems": [{ "SalesOrderNumber", "DateCreated", … }] }`.
    public static func parseOrderHistory(_ data: Data) throws -> [OrderSummary] {
        guard let root = object(data) as? JSON else { throw SupplierError("mouser", "Mouser sent something that isn’t JSON.") }
        try orderErrors(root)
        return ((root["OrderHistoryItems"] as? [JSON]) ?? []).compactMap { o in
            let number = str(o["SalesOrderNumber"]), web = str(o["WebOrderNumber"])
            guard !number.isEmpty || !web.isEmpty else { return nil }
            var s = OrderSummary(supplier: "mouser", number: number.isEmpty ? web : number)
            s.webNumber = web
            s.date = orderDate(o["DateCreated"])
            s.status = str(o["OrderStatusDisplay"])
            return s
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// `GET /orderhistory/salesOrderNumber` → `{ "OrderLines": [{ "Quantity", "UnitPrice", "ProductInfo": {…} }], … }`.
    public static func parseOrderDetail(_ data: Data, number: String) throws -> SupplierOrder {
        guard let root = object(data) as? JSON else { throw SupplierError("mouser", "Mouser sent something that isn’t JSON.") }
        try orderErrors(root)
        var order = SupplierOrder(supplier: "mouser")
        order.number = str(root["SalesOrderId"]).isEmpty ? number : str(root["SalesOrderId"])
        let cur = str(root["CurrencyCode"])
        order.currency = cur.isEmpty ? nil : cur
        for (i, li) in ((root["OrderLines"] as? [JSON]) ?? []).enumerated() {
            let p = li["ProductInfo"] as? JSON
            var l = SupplierOrder.Line(id: i, supplier: "mouser")
            l.spn = str(p?["MouserPartNumber"])
            if l.spn.uppercased() == "N/A" { l.spn = "" }
            l.mpn = str(p?["ManufacturerPartNumber"])
            l.manufacturer = str(p?["ManufacturerName"])
            l.description = str(p?["PartDescription"])
            l.customerReference = str(p?["CustomerPartNumber"])
            l.qty = Int(num(li["Quantity"]) ?? 0)
            l.unitPrice = num(li["UnitPrice"])
            if !l.spn.isEmpty || !l.mpn.isEmpty { order.lines.append(l) }
        }
        return order
    }

    static func orderErrors(_ root: JSON) throws {
        guard let first = (root["Errors"] as? [JSON])?.first else { return }
        let msg = str(first["Message"]).isEmpty ? str(first["Code"]) : str(first["Message"])
        throw SupplierError("mouser", describeOrders(msg))
    }

    static func describeOrders(_ message: String, status: Int? = nil) -> String {
        let m = message.lowercased()
        if m.contains("unique identifier") || m.contains("api key") || m.contains("apikey") || m.contains("invalid") || status == 401 || status == 403 {
            return "Mouser refused the Order History key (\(message)). It's a different key from the Search API one: mouser.com/api-hub › Order History API."
        }
        return "Mouser: \(message)"
    }
}

/// Lists orders with a Mouser Order History API key (not the Search API key).
public struct MouserOrdersClient: Sendable {
    let apiKey: String, session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    /// Every order Mouser has for the account, newest first, without their lines.
    public func orders() async throws -> [OrderSummary] {
        try MouserAPI.parseOrderHistory(try await get("orderhistory/ByDateFilter", [.init(name: "dateFilter", value: "All")]))
    }

    /// One order's lines.
    public func order(_ salesOrderNumber: String) async throws -> SupplierOrder {
        try MouserAPI.parseOrderDetail(try await get("orderhistory/salesOrderNumber", [.init(name: "salesOrderNumber", value: salesOrderNumber)]),
                                       number: salesOrderNumber)
    }

    private func get(_ path: String, _ query: [URLQueryItem]) async throws -> Data {
        guard !apiKey.isEmpty else { throw SupplierError("mouser", "Add your Mouser Order History API key in Settings to see your orders.") }
        var c = URLComponents(url: MouserAPI.host.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "apiKey", value: apiKey)] + query
        var req = URLRequest(url: c.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var message = "HTTP \(status)"
            if let root = object(data) as? JSON, let first = (root["Errors"] as? [JSON])?.first {
                message = str(first["Message"]).isEmpty ? str(first["Code"]) : str(first["Message"])
            }
            throw SupplierError("mouser", MouserAPI.describeOrders(message, status: status), status: status)
        }
        return data
    }
}
