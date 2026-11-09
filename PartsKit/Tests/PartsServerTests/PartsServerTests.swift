import Foundation
import Testing
import PartsKit
@testable import PartsServer

private let token = "test-token"

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("partsd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func server(_ dir: URL) throws -> PartsServer {
    try PartsServer(dataDirectory: dir, lookup: SupplierLookup(digikeyID: "", digikeySecret: "", mouserKey: ""))
}

/// A request through the whole front door, with the token unless `auth` is false.
private func call(_ s: PartsServer, _ method: String, _ target: String, _ body: JSONValue? = nil, auth: Bool = true) async -> (Int, JSONValue) {
    let (path, query) = HTTPParser.splitTarget(target)
    var headers = ["host": "127.0.0.1:8765"]
    if auth { headers["authorization"] = "Bearer \(token)" }
    if body != nil { headers["content-type"] = "application/json" }
    let req = HTTPRequest(method: method, path: path, query: query, headers: headers, body: body.map(JSONValue.encode) ?? Data())
    let res = await s.gate(token: { token }).handle(req)
    return (res.status, (try? JSONDecoder().decode(JSONValue.self, from: res.body)) ?? .null)
}

@Test func partsLifecycleOverREST() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = try server(dir)

    #expect(await call(s, "GET", "/api/health", auth: false).0 == 200)
    #expect(await call(s, "GET", "/api/parts", auth: false).0 == 401)

    let (created, part) = await call(s, "POST", "/api/parts",
                                     .object(["mpn": .string("RC0603FR-0710KL"), "paramsText": .string("10k 1% 0603"), "qty": .number(100),
                                              "location": .string("Cabinet A / Drawer 3"), "tags": .string("smd, resistor")]))
    #expect(created == 201)
    let id = try #require(part["id"]?.string)
    #expect(part["locationPath"]?.string == "Cabinet A › Drawer 3")
    #expect(part["qty"]?.int == 100)

    // Values in the query match the parsed parameters.
    let (_, found) = await call(s, "GET", "/api/parts?q=10k%200603")
    #expect(found["total"]?.int == 1)
    #expect(await call(s, "GET", "/api/parts?q=22k").1["total"]?.int == 0)

    let (_, used) = await call(s, "POST", "/api/parts/\(id)/stock", .object(["delta": .number(-30), "note": .string("amp build")]))
    #expect(used["qty"]?.int == 70)
    #expect(used["changed"]?.int == -30)
    let (_, detail) = await call(s, "GET", "/api/parts/\(id)")
    #expect(detail["history"]?.array?.first?["reason"]?.string == "API — amp build")

    #expect(await call(s, "PATCH", "/api/parts/\(id)", .object(["lowStock": .number(80)])).1["isLow"]?.bool == true)
    #expect(await call(s, "GET", "/api/locations").1["locations"]?.array?.count == 2)
    #expect(await call(s, "POST", "/api/identify", .object(["image": .string("")])).0 == 501)
    #expect(await call(s, "GET", "/api/lookup?q=LM358").0 == 409)
    #expect(await call(s, "GET", "/api/openapi.json").1["paths"]?["/api/identify"] == nil)

    // Everything is on disk: a new server over the same directory sees it.
    let again = try server(dir)
    #expect(await call(again, "GET", "/api/parts/\(id)").1["qty"]?.int == 70)

    #expect(await call(again, "DELETE", "/api/parts/\(id)").0 == 200)
    #expect(await call(again, "GET", "/api/parts/\(id)").0 == 404)
}

@Test func backupRoundTripWithPhotos() async throws {
    let a = try tempDir(), b = try tempDir()
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let s = try server(a)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    let (_, part) = await call(s, "POST", "/api/parts", .object(["mpn": .string("LM358DR"), "qty": .number(5), "photo": .string(png.base64EncodedString())]))
    let id = try #require(part["id"]?.string)
    #expect(part["photoCount"]?.int == 1)

    let export = try await s.backup(photos: true).encoded()
    let t = try server(b)
    let r = try await t.importBackup(export)
    #expect(r.added == 1 && r.photos == 1)
    let photo = try await t.photo(id, index: 0)
    #expect(photo.0 == png && photo.1 == "image/png")

    // Importing the same backup again changes nothing: same ids, nothing newer.
    let again = try await t.importBackup(export)
    #expect(again.added == 0 && again.updated == 0 && again.photos == 0)
    #expect(try await t.backup(photos: false).history.count == 1)
}

@Test func mcpTools() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = try server(dir)
    #expect(!PartsServerTools.list.contains { $0.name == "identify_photo" })
    #expect(PartsServerTools.list.count == InventoryCatalog.tools.count - 1)

    let tools = PartsServerTools(server: s)
    let added = await tools.call("add_part", arguments: ["mpn": .string("NE555P"), "qty": .number(3), "lookup": .bool(false)])
    #expect(!added.isError)
    let id = try #require(added.data?["id"]?.string)
    #expect(await tools.call("adjust_stock", arguments: ["id": .string(id), "delta": .number(2)]).summary == "NE555P: +2, now 5.")
    #expect(await tools.call("delete_part", arguments: ["id": .string(id)]).isError)
    #expect(await tools.call("search_parts", arguments: ["query": .string("ne555")]).summary == "1 part matching.")

    // tools/list over the MCP endpoint.
    let rpc = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")])
    let (status, res) = await call(s, "POST", "/mcp", rpc)
    #expect(status == 200)
    #expect(res["result"]?["tools"]?.array?.count == PartsServerTools.list.count)
}
