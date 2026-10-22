import Foundation
import Testing
@testable import PartsKit

// Trimmed replies in the shapes Digi-Key's Product Information v4 and Mouser's Search API v1 send.
let dkDetails = #"""
{"Product":{
  "Description":{"ProductDescription":"IC OPAMP GP 2 CIRCUIT 8SOIC","DetailedDescription":"General Purpose Amplifier 2 Circuit 8-SOIC"},
  "Manufacturer":{"Id":296,"Name":"Texas Instruments"},
  "ManufacturerProductNumber":"LM358DR","UnitPrice":0.42,
  "ProductUrl":"https://www.digikey.com/en/products/detail/texas-instruments/LM358DR/555973",
  "DatasheetUrl":"//www.ti.com/lit/ds/symlink/lm358.pdf",
  "PhotoUrl":"https://mm.digikey.com/Volume0/opasdata/d220001/medias/images/1234/296-8-SOIC.jpg",
  "ProductVariations":[
    {"DigiKeyProductNumber":"296-1395-6-ND","PackageType":{"Id":243,"Name":"Digi-Reel®"},"StandardPricing":[{"BreakQuantity":1,"UnitPrice":0.42,"TotalPrice":0.42}]},
    {"DigiKeyProductNumber":"296-1395-2-ND","PackageType":{"Id":1,"Name":"Tape & Reel (TR)"},"StandardPricing":[{"BreakQuantity":2500,"UnitPrice":0.11,"TotalPrice":275}]},
    {"DigiKeyProductNumber":"296-1395-1-ND","PackageType":{"Id":2,"Name":"Cut Tape (CT)"},"StandardPricing":[{"BreakQuantity":10,"UnitPrice":0.307,"TotalPrice":3.07},{"BreakQuantity":1,"UnitPrice":0.42,"TotalPrice":0.42},{"BreakQuantity":100,"UnitPrice":0.2,"TotalPrice":20}]}
  ],
  "QuantityAvailable":184213,
  "ProductStatus":{"Id":0,"Status":"Active"},
  "Parameters":[
    {"ParameterId":16,"ParameterText":"Package / Case","ParameterType":"String","ValueId":"1","ValueText":"8-SOIC (0.154\", 3.90mm Width)"},
    {"ParameterId":1291,"ParameterText":"Supplier Device Package","ParameterType":"String","ValueId":"2","ValueText":"8-SOIC"},
    {"ParameterId":2094,"ParameterText":"Voltage - Supply Span (Max)","ParameterType":"String","ValueId":"3","ValueText":"32 V"},
    {"ParameterId":9,"ParameterText":"Grade","ParameterType":"String","ValueId":"0","ValueText":"-"}
  ],
  "Category":{"CategoryId":32,"Name":"Integrated Circuits (ICs)","ChildCategories":[{"CategoryId":687,"Name":"Instrumentation, Op Amps, Buffer Amps","ChildCategories":[]}]}
}}
"""#

let dkKeyword = #"""
{"Products":[
  {"ManufacturerProductNumber":"LM358DR","Manufacturer":{"Name":"Texas Instruments"},"Description":{"ProductDescription":"IC OPAMP GP 2 CIRCUIT 8SOIC"},"QuantityAvailable":0,"ProductVariations":[{"DigiKeyProductNumber":"296-1395-1-ND","StandardPricing":[{"BreakQuantity":1,"UnitPrice":0.42}]}]},
  {"ManufacturerProductNumber":"LM358DR2G","Manufacturer":{"Name":"onsemi"},"Description":{"ProductDescription":"IC OPAMP GP 2 CIRCUIT 8SOIC"},"QuantityAvailable":5000,"ProductVariations":[{"DigiKeyProductNumber":"LM358DR2GOSCT-ND","StandardPricing":[]}],"UnitPrice":0.5}
],
"ExactMatches":[
  {"ManufacturerProductNumber":"LM358DR","Manufacturer":{"Name":"Texas Instruments"},"Description":{"ProductDescription":"IC OPAMP GP 2 CIRCUIT 8SOIC"},"QuantityAvailable":0,"ProductVariations":[{"DigiKeyProductNumber":"296-1395-1-ND","StandardPricing":[{"BreakQuantity":1,"UnitPrice":0.42}]}]}
],
"ProductsCount":2}
"""#

let dkProblem = #"{"type":"https://tools.ietf.org/html/rfc7235#section-3.1","title":"Unauthorized","status":401,"detail":"Invalid token","correlationId":"abc"}"#
let dkOldError = #"{"ErrorResponseVersion":"3.0.0","StatusCode":429,"ErrorMessage":"Daily ratelimit exceeded","ErrorDetails":"","RequestId":"x"}"#

let mouserReply = #"""
{"Errors":[],"SearchResults":{"NumberOfResult":1,"Parts":[{
  "Availability":"12,345 In Stock","AvailabilityInStock":"12345",
  "Category":"Operational Amplifiers - Op Amps",
  "DataSheetUrl":"https://www.mouser.com/datasheet/2/405/lm358-1.pdf",
  "Description":"Operational Amplifiers - Op Amps Dual Op Amp",
  "ImagePath":"https://www.mouser.com/images/texasinstruments/images/SOIC_8_t.jpg",
  "LifecycleStatus":null,
  "Manufacturer":"Texas Instruments","ManufacturerPartNumber":"LM358DR","MouserPartNumber":"595-LM358DR",
  "PriceBreaks":[{"Quantity":1,"Price":"$0.42","Currency":"USD"},{"Quantity":10,"Price":"$0.307","Currency":"USD"},{"Quantity":1000,"Price":"$1,234.50","Currency":"USD"}],
  "ProductAttributes":[{"AttributeName":"Packaging","AttributeValue":"Reel"},{"AttributeName":"Packaging","AttributeValue":"Cut Tape"},{"AttributeName":"Package / Case","AttributeValue":"SOIC-8"}],
  "ProductDetailUrl":"https://www.mouser.com/ProductDetail/Texas-Instruments/LM358DR?qs=abc"
}]}}
"""#

let mouserBadKey = #"{"Errors":[{"Id":0,"Code":"Invalid","Message":"Invalid unique identifier.","ResourceKey":"InvalidIdentifier","ResourceFormatString":null,"ResourceFormatString2":null,"PropertyName":"API Key"}],"SearchResults":null}"#

@Test func digikeyDetails() throws {
    let r = try DigiKeyAPI.parseDetails(Data(dkDetails.utf8))
    #expect(r.count == 1)
    let p = r[0]
    #expect([p.supplier, p.mpn, p.manufacturer, p.spn, p.status] == ["digikey", "LM358DR", "Texas Instruments", "296-1395-1-ND", "Active"])
    #expect(p.prices.map(\.qty) == [1, 10, 100])
    #expect(p.unitPrice(for: 25)?.unit == 0.307)
    #expect(p.unitPrice(for: 1)?.unit == 0.42)
    #expect(p.stock == 184213)
    #expect(p.datasheet == "https://www.ti.com/lit/ds/symlink/lm358.pdf")
    #expect(p.category == "Instrumentation, Op Amps, Buffer Amps")
    #expect(p.package == "8-SOIC")
    #expect(!p.parameters.contains { $0.name == "Grade" })
    let e = p.supplierEntry(now: Date(timeIntervalSince1970: 1))
    #expect(e.supplier == "digikey" && e.pn == "296-1395-1-ND" && e.breaks.count == 3 && e.stock == 184213 && e.updated == 1000)
}

@Test func digikeyKeyword() throws {
    let r = try DigiKeyAPI.parseKeyword(Data(dkKeyword.utf8))
    #expect(r.map(\.mpn) == ["LM358DR", "LM358DR2G"])   // the exact match isn't repeated
    #expect(r[1].prices.first?.unit == 0.5)               // no breaks: the unit price stands in
}

@Test func digikeyErrors() {
    #expect(throws: SupplierError.self) { try DigiKeyAPI.parseDetails(Data(dkProblem.utf8)) }
    do { _ = try DigiKeyAPI.parseKeyword(Data(dkOldError.utf8)); Issue.record("no error") } catch let e as SupplierError {
        #expect(e.status == 429 && e.message.contains("rate limit"))
    } catch { Issue.record("\(error)") }
    do { _ = try DigiKeyAPI.parseDetails(Data(dkProblem.utf8)) } catch let e as SupplierError {
        #expect(e.message.contains("client ID or secret"))
    } catch { Issue.record("\(error)") }
}

@Test func mouserParse() throws {
    let r = try MouserAPI.parse(Data(mouserReply.utf8))
    #expect(r.count == 1)
    let p = r[0]
    #expect([p.supplier, p.spn, p.mpn, p.manufacturer, p.package, p.status] == ["mouser", "595-LM358DR", "LM358DR", "Texas Instruments", "SOIC-8", ""])
    #expect(p.stock == 12345)
    #expect(p.prices.map(\.unit) == [0.42, 0.307, 1234.5])
    #expect(p.parameters.first { $0.name == "Packaging" }?.value == "Reel, Cut Tape")
    #expect(p.normalisedPackage == Values.normPackage("SOIC-8"))
}

@Test func mouserErrors() {
    do { _ = try MouserAPI.parse(Data(mouserBadKey.utf8)); Issue.record("no error") } catch let e as SupplierError {
        #expect(e.supplier == "mouser" && e.message.contains("API key"))
    } catch { Issue.record("\(error)") }
    #expect((try? MouserAPI.parse(Data(#"{"Errors":[],"SearchResults":{"NumberOfResult":0,"Parts":[]}}"#.utf8)))?.isEmpty == true)
}

@Test func moneyParsing() {
    #expect(money("$0.12") == 0.12)
    #expect(money("$1,234.56") == 1234.56)
    #expect(money("0,12 €") == 0.12)
    #expect(money("1,234") == 1234)
}

@Test func ranking() {
    var a = SupplierProduct(supplier: "mouser"); a.mpn = "LM358DR2G"; a.stock = 10
    var b = SupplierProduct(supplier: "digikey"); b.mpn = "LM358DR"; b.stock = 0
    var c = SupplierProduct(supplier: "digikey"); c.mpn = "XLM358"; c.stock = 99
    var d = SupplierProduct(supplier: "mouser"); d.mpn = "LM358DR"; d.stock = 5
    #expect(SupplierLookup.rank([c, a, b, d], query: "lm358-dr").map(\.id) == [d.id, b.id, a.id, c.id])
}

@Test func lookupWithoutKeys() async {
    let s = SupplierLookup(digikeyID: " ", digikeySecret: "", mouserKey: "")
    #expect(!s.isConfigured)
    let r = await s.lookup("LM358")
    #expect(r.products.isEmpty && r.errors.isEmpty)
}

@Test func draftFilledFromListing() throws {
    let p = try DigiKeyAPI.parseDetails(Data(dkDetails.utf8))[0]
    var d = PartDraft(); d.mpn = "LM358DR"; d.manufacturer = "TI"
    d.fill(from: p)
    #expect(d.manufacturer == "TI")                       // kept
    #expect(d.description == "IC OPAMP GP 2 CIRCUIT 8SOIC")
    #expect(d.datasheet.hasSuffix("lm358.pdf") && !d.package.isEmpty)
    #expect(d.suppliers.map(\.pn) == ["296-1395-1-ND"])
    d.fill(from: p)
    #expect(d.suppliers.count == 1)                       // not repeated
}
