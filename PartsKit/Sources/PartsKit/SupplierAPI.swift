import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A part as a supplier's API describes it, in one shape for every supplier.
public struct SupplierProduct: Sendable, Hashable, Identifiable {
    public struct Price: Sendable, Hashable {
        public var qty: Int
        public var unit: Double
        public var currency: String
        public init(qty: Int, unit: Double, currency: String) { self.qty = qty; self.unit = unit; self.currency = currency }
    }
    public struct Parameter: Sendable, Hashable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    /// "digikey" or "mouser", as in `Supplier.all`.
    public var supplier: String
    /// The supplier's own part number.
    public var spn = ""
    public var mpn = ""
    public var manufacturer = ""
    public var description = ""
    public var detail = ""
    public var datasheet = ""
    public var url = ""
    public var image = ""
    public var stock: Int?
    /// Price breaks, lowest quantity first.
    public var prices: [Price] = []
    public var package = ""
    public var category = ""
    public var status = ""
    public var parameters: [Parameter] = []

    public init(supplier: String) { self.supplier = supplier }

    public var id: String { "\(supplier):\(spn.isEmpty ? mpn : spn)" }
    public var supplierName: String { Supplier.named(supplier)?.name ?? supplier }

    /// The unit price when buying `qty`: the largest break at or below it (the first break if `qty` is below them all).
    public func unitPrice(for qty: Int) -> Price? {
        prices.last { $0.qty <= qty } ?? prices.first
    }

    /// The package in the inventory's form ("0603", "SOIC-8"…).
    public var normalisedPackage: String { package.isEmpty ? "" : Values.normPackage(package) }

    /// The supplier entry to keep on a part: number, price breaks, stock and link.
    public func supplierEntry(now: Date = .now) -> SupplierEntry {
        var e = SupplierEntry(supplier: supplier, pn: spn.isEmpty ? mpn : spn)
        e.breaks = prices.map { .init(qty: Double($0.qty), unit: $0.unit) }
        e.currency = prices.first?.currency
        e.stock = stock.map(Double.init)
        e.moq = prices.first.map { Double($0.qty) }
        e.url = url
        e.updated = now.jsTime
        return e
    }

    /// Value, tolerance, voltage… read from the description and parameters.
    public func params(kind: String? = nil) -> PartParams {
        let text = ([description, detail] + parameters.map(\.value)).joined(separator: " ")
        return Values.params(from: text, kind: kind, footprint: package.isEmpty ? nil : package)
    }
}

/// A supplier API's refusal, in words a person can act on.
public struct SupplierError: LocalizedError, Sendable, Equatable {
    public var supplier: String
    public var message: String
    public var status: Int?
    public init(_ supplier: String, _ message: String, status: Int? = nil) { self.supplier = supplier; self.message = message; self.status = status }
    public var errorDescription: String? { message }
}

// MARK: - Parsing helpers

typealias JSON = [String: Any]

private func object(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }
private func str(_ v: Any?) -> String {
    switch v {
    case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
    case let n as NSNumber: return n.stringValue
    default: return ""
    }
}
private func num(_ v: Any?) -> Double? {
    switch v {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return money(s)
    default: return nil
    }
}
/// "$1,234.56", "0.123 €" → 1234.56, 0.123.
func money(_ s: String) -> Double? {
    let kept = s.filter { $0.isNumber || $0 == "." || $0 == "," }
    // A comma with no point after it and two or three digits after it is a decimal comma ("0,12").
    if !kept.contains("."), let i = kept.lastIndex(of: ","), kept.distance(from: i, to: kept.endIndex) - 1 < 3 {
        return Double(kept.replacingOccurrences(of: ",", with: "."))
    }
    return Double(kept.replacingOccurrences(of: ",", with: ""))
}
/// Protocol-relative and http links made https.
private func link(_ v: Any?) -> String {
    var s = str(v)
    if s.hasPrefix("//") { s = "https:" + s }
    if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
    return s
}
private func packageFrom(_ params: [SupplierProduct.Parameter]) -> String {
    let names = ["Supplier Device Package", "Package / Case", "Package/Case", "Package", "Case/Package"]
    for n in names { if let p = params.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }), !p.value.isEmpty, p.value != "-" { return p.value } }
    return ""
}

// MARK: - Digi-Key

/// Digi-Key's Product Information API, v4.
public enum DigiKeyAPI {
    public static let host = URL(string: "https://api.digikey.com")!

    /// `GET /products/v4/search/{number}/productdetails` → `{ "Product": {…} }`.
    public static func parseDetails(_ data: Data) throws -> [SupplierProduct] {
        guard let root = object(data) as? JSON else { throw SupplierError("digikey", "Digi-Key sent something that isn’t JSON.") }
        if let e = problem(root) { throw e }
        guard let p = root["Product"] as? JSON else { return [] }
        return [product(p)]
    }

    /// `POST /products/v4/search/keyword` → `{ "ExactMatches": […], "Products": […], "ProductsCount": n }`.
    public static func parseKeyword(_ data: Data) throws -> [SupplierProduct] {
        guard let root = object(data) as? JSON else { throw SupplierError("digikey", "Digi-Key sent something that isn’t JSON.") }
        if let e = problem(root) { throw e }
        let all = ((root["ExactMatches"] as? [JSON]) ?? []) + ((root["Products"] as? [JSON]) ?? [])
        var seen = Set<String>()
        return all.map(product).filter { seen.insert($0.id).inserted }
    }

    /// The error in a Digi-Key reply (problem details, or the older error shape), if there is one.
    static func problem(_ root: JSON, status: Int? = nil) -> SupplierError? {
        let detail = [root["detail"], root["ErrorMessage"], root["error_description"], root["message"], root["title"], root["ErrorDetails"]]
            .map(str).first { !$0.isEmpty }
        let code = (root["status"] as? Int) ?? (root["StatusCode"] as? Int) ?? status
        guard let detail else { return nil }
        return SupplierError("digikey", describe(detail, status: code), status: code)
    }

    static func describe(_ detail: String, status: Int?) -> String {
        switch status {
        case 401, 403: return "Digi-Key refused the client ID or secret (\(detail)). Check them in Settings, and that the app is subscribed to Product Information V4."
        case 429: return "Digi-Key’s rate limit was reached (\(detail)). Try again in a minute — the free limit is about 1,000 lookups a day."
        default: return "Digi-Key: \(detail)"
        }
    }

    static func product(_ p: JSON) -> SupplierProduct {
        var r = SupplierProduct(supplier: "digikey")
        r.mpn = str(p["ManufacturerProductNumber"])
        r.manufacturer = str((p["Manufacturer"] as? JSON)?["Name"])
        let d = p["Description"] as? JSON
        r.description = str(d?["ProductDescription"])
        r.detail = str(d?["DetailedDescription"])
        r.datasheet = link(p["DatasheetUrl"])
        r.url = link(p["ProductUrl"])
        r.image = link(p["PhotoUrl"])
        r.stock = num(p["QuantityAvailable"]).map { Int($0) }
        r.status = str((p["ProductStatus"] as? JSON)?["Status"])
        r.category = deepestCategory(p["Category"] as? JSON)
        r.parameters = ((p["Parameters"] as? [JSON]) ?? []).compactMap { q in
            let n = str(q["ParameterText"]), v = str(q["ValueText"])
            return n.isEmpty || v.isEmpty || v == "-" ? nil : .init(name: n, value: v)
        }
        r.package = packageFrom(r.parameters)
        let currency = "USD"
        // Variations are packagings (cut tape, reel, Digi-Reel): take the one that sells the fewest.
        let variations = ((p["ProductVariations"] as? [JSON]) ?? []).map { v -> (spn: String, prices: [SupplierProduct.Price], kind: String) in
            let prices = ((v["StandardPricing"] as? [JSON]) ?? []).compactMap { b -> SupplierProduct.Price? in
                guard let q = num(b["BreakQuantity"]), let u = num(b["UnitPrice"]) else { return nil }
                return .init(qty: Int(q), unit: u, currency: currency)
            }.sorted { $0.qty < $1.qty }
            return (str(v["DigiKeyProductNumber"]), prices, str((v["PackageType"] as? JSON)?["Name"]))
        }.filter { !$0.spn.isEmpty }
        let best = variations.filter { !$0.kind.localizedCaseInsensitiveContains("Digi-Reel") }
            .min { ($0.prices.first?.qty ?? .max) < ($1.prices.first?.qty ?? .max) } ?? variations.first
        r.spn = best?.spn ?? str(p["DigiKeyProductNumber"])
        r.prices = best?.prices ?? []
        if r.prices.isEmpty, let u = num(p["UnitPrice"]), u > 0 { r.prices = [.init(qty: 1, unit: u, currency: currency)] }
        return r
    }

    private static func deepestCategory(_ c: JSON?) -> String {
        guard let c else { return "" }
        if let kids = c["ChildCategories"] as? [JSON], let first = kids.first {
            let deeper = deepestCategory(first)
            if !deeper.isEmpty { return deeper }
        }
        return str(c["Name"])
    }
}

/// Signs in with the app's client ID and secret (2-legged OAuth) and looks parts up.
public actor DigiKeyClient {
    let clientID: String, secret: String, session: URLSession
    private var token: (value: String, expires: Date)?

    public init(clientID: String, secret: String, session: URLSession = .shared) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    /// The part by Digi-Key or manufacturer number; a keyword search when there is no exact one.
    public func lookup(_ partNumber: String) async throws -> [SupplierProduct] {
        let q = partNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? q
        do {
            let found = try DigiKeyAPI.parseDetails(try await call("GET", "/products/v4/search/\(enc)/productdetails"))
            if !found.isEmpty { return found }
        } catch let e as SupplierError where e.status == 404 || e.status == 400 {
            // Not a number Digi-Key knows exactly: search instead.
        }
        return try await search(q)
    }

    public func search(_ keywords: String, limit: Int = 10) async throws -> [SupplierProduct] {
        let body = try JSONSerialization.data(withJSONObject: ["Keywords": keywords, "Limit": limit, "Offset": 0])
        return try DigiKeyAPI.parseKeyword(try await call("POST", "/products/v4/search/keyword", body: body))
    }

    private func call(_ method: String, _ path: String, body: Data? = nil, retry: Bool = true) async throws -> Data {
        var req = URLRequest(url: URL(string: DigiKeyAPI.host.absoluteString + path)!)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "X-DIGIKEY-Client-Id")
        req.setValue("US", forHTTPHeaderField: "X-DIGIKEY-Locale-Site")
        req.setValue("en", forHTTPHeaderField: "X-DIGIKEY-Locale-Language")
        req.setValue("USD", forHTTPHeaderField: "X-DIGIKEY-Locale-Currency")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, retry { token = nil; return try await call(method, path, body: body, retry: false) }
        guard (200..<300).contains(status) else { throw failure(data, status: status) }
        return data
    }

    private func accessToken() async throws -> String {
        if let t = token, t.expires > .now.addingTimeInterval(30) { return t.value }
        guard !clientID.isEmpty, !secret.isEmpty else { throw SupplierError("digikey", "Add your Digi-Key client ID and secret in Settings.") }
        var req = URLRequest(url: DigiKeyAPI.host.appendingPathComponent("v1/oauth2/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["client_id": clientID, "client_secret": secret, "grant_type": "client_credentials"]
        req.httpBody = form.map { k, v in "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v)" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let root = object(data) as? JSON, let t = root["access_token"] as? String else {
            throw failure(data, status: status == 200 ? 401 : status)
        }
        let life = num(root["expires_in"]) ?? 600
        token = (t, .now.addingTimeInterval(life))
        return t
    }

    private func failure(_ data: Data, status: Int) -> SupplierError {
        if let root = object(data) as? JSON, var e = DigiKeyAPI.problem(root, status: status) { e.status = status; return e }
        let text = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return SupplierError("digikey", DigiKeyAPI.describe(text.isEmpty ? "HTTP \(status)" : text, status: status), status: status)
    }
}

// MARK: - Mouser

/// Mouser's Search API, v1.
public enum MouserAPI {
    public static let host = URL(string: "https://api.mouser.com/api/v1")!

    /// A search reply: `{ "Errors": […], "SearchResults": { "NumberOfResult": n, "Parts": […] } }`.
    public static func parse(_ data: Data) throws -> [SupplierProduct] {
        guard let root = object(data) as? JSON else { throw SupplierError("mouser", "Mouser sent something that isn’t JSON.") }
        if let errors = root["Errors"] as? [JSON], let first = errors.first {
            let msg = str(first["Message"]).isEmpty ? str(first["Code"]) : str(first["Message"])
            throw SupplierError("mouser", describe(msg))
        }
        let parts = ((root["SearchResults"] as? JSON)?["Parts"] as? [JSON]) ?? []
        return parts.map(product).filter { !$0.mpn.isEmpty || !$0.spn.isEmpty }
    }

    static func describe(_ message: String, status: Int? = nil) -> String {
        let m = message.lowercased()
        if m.contains("unique identifier") || m.contains("api key") || m.contains("apikey") || status == 401 || status == 403 {
            return "Mouser refused the API key (\(message)). Check it in Settings — it’s the Search API key, not the Order API key."
        }
        if status == 429 || m.contains("too many") || m.contains("exceeded") {
            return "Mouser’s rate limit was reached (\(message)). It allows 30 lookups a minute and 1,000 a day."
        }
        return "Mouser: \(message)"
    }

    static func product(_ p: JSON) -> SupplierProduct {
        var r = SupplierProduct(supplier: "mouser")
        r.spn = str(p["MouserPartNumber"])
        if r.spn.uppercased() == "N/A" { r.spn = "" }
        r.mpn = str(p["ManufacturerPartNumber"])
        r.manufacturer = str(p["Manufacturer"])
        r.description = str(p["Description"])
        r.datasheet = link(p["DataSheetUrl"])
        r.url = link(p["ProductDetailUrl"])
        r.image = link(p["ImagePath"])
        r.category = str(p["Category"])
        r.status = str(p["LifecycleStatus"])
        if let s = num(p["AvailabilityInStock"]) { r.stock = Int(s) }
        else if let a = p["Availability"] as? String, let n = Int(a.prefix { $0.isNumber || $0 == "," }.filter(\.isNumber)) { r.stock = n }
        r.prices = ((p["PriceBreaks"] as? [JSON]) ?? []).compactMap { b -> SupplierProduct.Price? in
            guard let q = num(b["Quantity"]), let u = num(b["Price"]) else { return nil }
            return .init(qty: Int(q), unit: u, currency: str(b["Currency"]).isEmpty ? "USD" : str(b["Currency"]))
        }.sorted { $0.qty < $1.qty }
        // Attributes repeat a name for a list of values (e.g. Packaging: Reel, Cut Tape): join them.
        var params: [SupplierProduct.Parameter] = []
        for a in (p["ProductAttributes"] as? [JSON]) ?? [] {
            let n = str(a["AttributeName"]), v = str(a["AttributeValue"])
            guard !n.isEmpty, !v.isEmpty else { continue }
            if let i = params.firstIndex(where: { $0.name == n }) { params[i].value += ", " + v } else { params.append(.init(name: n, value: v)) }
        }
        r.parameters = params
        r.package = packageFrom(params)
        return r
    }
}

/// Looks parts up with a Mouser Search API key.
public struct MouserClient: Sendable {
    let apiKey: String, session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    /// The part by Mouser or manufacturer number (exact, then begins-with), then a keyword search.
    public func lookup(_ partNumber: String) async throws -> [SupplierProduct] {
        let q = partNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        for option in ["Exact", "BeginsWith"] {
            let found = try await post("search/partnumber", ["SearchByPartRequest": ["mouserPartNumber": q, "partSearchOptions": option]])
            if !found.isEmpty { return found }
        }
        return try await search(q)
    }

    public func search(_ keyword: String, records: Int = 10) async throws -> [SupplierProduct] {
        try await post("search/keyword", ["SearchByKeywordRequest": ["keyword": keyword, "records": records, "startingRecord": 0]])
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [SupplierProduct] {
        guard !apiKey.isEmpty else { throw SupplierError("mouser", "Add your Mouser Search API key in Settings.") }
        var c = URLComponents(url: MouserAPI.host.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "apiKey", value: apiKey)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Mouser usually explains itself in "Errors"; otherwise say what HTTP said.
            var message = "HTTP \(status)"
            if let root = object(data) as? JSON, let first = (root["Errors"] as? [JSON])?.first {
                message = str(first["Message"]).isEmpty ? str(first["Code"]) : str(first["Message"])
            }
            throw SupplierError("mouser", MouserAPI.describe(message, status: status), status: status)
        }
        return try MouserAPI.parse(data)
    }
}

// MARK: - Both

/// Asks every configured supplier at once.
public struct SupplierLookup: Sendable {
    public var digikey: DigiKeyClient?
    public var mouser: MouserClient?

    public init(digikey: DigiKeyClient? = nil, mouser: MouserClient? = nil) { self.digikey = digikey; self.mouser = mouser }

    /// Clients for whichever keys are filled in.
    public init(digikeyID: String, digikeySecret: String, mouserKey: String, session: URLSession = .shared) {
        let id = digikeyID.trimmingCharacters(in: .whitespaces), secret = digikeySecret.trimmingCharacters(in: .whitespaces)
        digikey = id.isEmpty || secret.isEmpty ? nil : DigiKeyClient(clientID: id, secret: secret, session: session)
        let key = mouserKey.trimmingCharacters(in: .whitespaces)
        mouser = key.isEmpty ? nil : MouserClient(apiKey: key, session: session)
    }

    public var isConfigured: Bool { digikey != nil || mouser != nil }

    public struct Result: Sendable {
        public var products: [SupplierProduct] = []
        /// Supplier id → what went wrong.
        public var errors: [String: String] = [:]
        public init() {}
    }

    public func lookup(_ query: String) async -> Result {
        let dkClient = digikey, moClient = mouser
        async let dk = Self.outcome { try await dkClient?.lookup(query) }
        async let mo = Self.outcome { try await moClient?.lookup(query) }
        var r = Result()
        let outcomes: [(String, Outcome)] = [("digikey", await dk), ("mouser", await mo)]
        for (id, outcome) in outcomes {
            switch outcome {
            case .found(let p): r.products += p
            case .failed(let message): r.errors[id] = message
            case .skipped: break
            }
        }
        r.products = Self.rank(r.products, query: query)
        return r
    }

    private enum Outcome: Sendable { case found([SupplierProduct]), failed(String), skipped }

    private static func outcome(_ f: @Sendable () async throws -> [SupplierProduct]?) async -> Outcome {
        do { return try await f().map(Outcome.found) ?? .skipped } catch { return .failed(error.localizedDescription) }
    }

    /// Whether each configured supplier answers: supplier id → nil (fine) or the error.
    public func test() async -> [String: String?] {
        let r = await lookup("LM358")
        var out: [String: String?] = [:]
        if digikey != nil { out["digikey"] = r.errors["digikey"] }
        if mouser != nil { out["mouser"] = r.errors["mouser"] }
        return out
    }

    /// Exact manufacturer or supplier numbers first, then numbers that start with the query, then the rest;
    /// in stock before out of stock within each.
    public static func rank(_ products: [SupplierProduct], query: String) -> [SupplierProduct] {
        func key(_ s: String) -> String { s.uppercased().filter { $0.isLetter || $0.isNumber } }
        let q = key(query)
        func tier(_ p: SupplierProduct) -> Int {
            if key(p.mpn) == q || key(p.spn) == q { return 0 }
            if key(p.mpn).hasPrefix(q) { return 1 }
            return 2
        }
        return products.enumerated().sorted { a, b in
            let ta = tier(a.element), tb = tier(b.element)
            if ta != tb { return ta < tb }
            let sa = (a.element.stock ?? 0) > 0, sb = (b.element.stock ?? 0) > 0
            if sa != sb { return sa }
            return a.offset < b.offset
        }.map(\.element)
    }
}
