import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
import PartsKit
@testable import Parts_Inventory

// The REST API and the MCP endpoint end to end: a real server on a free port, an in-memory store, URLSession.

@MainActor
final class APIHarness {
    let container: ModelContainer
    let api: InventoryAPI
    let server: HTTPServer
    var port: UInt16 = 0
    let token = "test-token-123"

    init() async throws {
        let schema = Schema(Schema1.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        api = InventoryAPI(container: container)
        api.lookup = { SupplierLookup() }   // no keys: lookups answer 409, nothing goes to the suppliers
        let mcp = MCPEndpoint(name: "parts-inventory", version: "test", instructions: "", provider: InventoryTools(api: api))
        let api = api, token = token
        let gate = APIGate(token: { token }, mcp: mcp) { req in await api.handle(req) }
        server = HTTPServer { req in await gate.handle(req) }
        try server.start(port: 0)
        guard case .listening(let p) = await server.waitUntilReady() else { throw HarnessError.notListening("\(server.state)") }
        port = p
    }
    enum HarnessError: Error { case notListening(String) }

    func call(_ method: String, _ path: String, json: JSONValue? = nil, body: Data? = nil, contentType: String? = nil,
              auth: Bool = true, headers: [String: String] = [:]) async throws -> (Int, JSONValue?, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        if auth { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json { req.httpBody = JSONValue.encode(json); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let body { req.httpBody = body; req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, res) = try await URLSession.shared.data(for: req)
        let http = res as! HTTPURLResponse
        return (http.statusCode, try? JSONDecoder().decode(JSONValue.self, from: data), http)
    }

    func rpc(_ method: String, _ params: JSONValue = .object([:]), id: Int = 1, session: String? = nil) async throws -> (JSONValue?, HTTPURLResponse) {
        var h = ["Accept": "application/json, text/event-stream"]
        if let session { h["Mcp-Session-Id"] = session; h["MCP-Protocol-Version"] = "2025-06-18" }
        let (_, j, res) = try await call("POST", "/mcp", json: .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]), headers: h)
        return (j, res)
    }
}

/// A small PNG with nothing on it.
func blankPNG() -> Data {
    let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

@MainActor @Test func restEndToEnd() async throws {
    let h = try await APIHarness()
    defer { h.server.stop() }

    #expect(try await h.call("GET", "/api/health", auth: false).0 == 200)
    #expect(try await h.call("GET", "/api/parts", auth: false).0 == 401)
    #expect(try await h.call("GET", "/api/parts", headers: ["Origin": "https://evil.example"]).0 == 403)
    #expect(try await h.call("GET", "/api/nothing").0 == 404)
    #expect(try await h.call("DELETE", "/api/parts").0 == 405)

    // Add, find, change.
    let (s1, made, _) = try await h.call("POST", "/api/parts", json: .object([
        "mpn": .string("LM358DR"), "manufacturer": .string("Texas Instruments"), "description": .string("Dual op amp"),
        "qty": .number(5), "location": .string("Cabinet A / Drawer 1"), "tags": .string("opamp, smd"), "package": .string("SOIC-8"),
        "photo": .string(blankPNG().base64EncodedString()),
    ]))
    #expect(s1 == 201)
    let id = try #require(made?["id"]?.string)
    #expect(made?["qty"]?.int == 5)
    #expect(made?["locationPath"]?.string == "Cabinet A › Drawer 1")
    #expect(made?["tags"] == .array([.string("opamp"), .string("smd")]))
    #expect(made?["photoCount"]?.int == 1)

    let (_, resistor, _) = try await h.call("POST", "/api/parts", json: .object(["mpn": .string("RC0603FR-0710KL"), "paramsText": .string("10k 1% 0603"), "qty": .number(100)]))
    #expect(resistor?["params"]?["value"]?.number == 10_000)
    #expect(try await h.call("POST", "/api/parts", json: .object(["qty": .number(1)])).0 == 400)

    let (_, found, _) = try await h.call("GET", "/api/parts?q=lm358")
    #expect(found?["total"]?.int == 1)
    let (_, byValue, _) = try await h.call("GET", "/api/parts?q=10k%200603")
    #expect(byValue?["parts"]?.array?.first?["mpn"]?.string == "RC0603FR-0710KL")
    let (_, byLoc, _) = try await h.call("GET", "/api/parts?location=drawer%201")
    #expect(byLoc?["total"]?.int == 1)

    let (_, took, _) = try await h.call("POST", "/api/parts/\(id)/stock", json: .object(["delta": .number(-2), "note": .string("amp build")]))
    #expect(took?["qty"]?.int == 3 && took?["changed"]?.int == -2)
    let (_, counted, _) = try await h.call("POST", "/api/parts/\(id)/stock", json: .object(["set": .number(10)]))
    #expect(counted?["qty"]?.int == 10)
    #expect(try await h.call("POST", "/api/parts/\(id)/stock", json: .object([:])).0 == 400)

    let (_, patched, _) = try await h.call("PATCH", "/api/parts/\(id)", json: .object(["notes": .string("in the amp"), "lowStock": .number(4)]))
    #expect(patched?["notes"]?.string == "in the amp")
    let (_, full, _) = try await h.call("GET", "/api/parts/\(id)")
    #expect(full?["history"]?.array?.count == 3)
    #expect(full?["history"]?.array?.contains { $0["reason"]?.string == "API — amp build" } == true)

    var photoReq = URLRequest(url: URL(string: "http://127.0.0.1:\(h.port)/api/parts/\(id)/photos/0")!)
    photoReq.setValue("Bearer \(h.token)", forHTTPHeaderField: "Authorization")
    let (photo, photoRes) = try await URLSession.shared.data(for: photoReq)
    #expect((photoRes as? HTTPURLResponse)?.statusCode == 200 && photo.count > 100)
    #expect(try await h.call("GET", "/api/parts/\(id)/photos/5").0 == 404)

    // Locations, projects, lookups.
    let (s2, loc, _) = try await h.call("POST", "/api/locations", json: .object(["path": .string("Shelf / Box 2")]))
    #expect(s2 == 201 && loc?["path"]?.string == "Shelf › Box 2")
    let (_, locs, _) = try await h.call("GET", "/api/locations")
    #expect(locs?["locations"]?.array?.count == 4)
    #expect(try await h.call("GET", "/api/projects").1?["projects"]?.array?.isEmpty == true)
    #expect(try await h.call("GET", "/api/lookup?q=LM358").0 == 409)

    // Backups both ways.
    let (_, backup, _) = try await h.call("GET", "/api/export")
    #expect(backup?["schema"]?.string == "gw-parts-inventory")
    #expect(backup?["parts"]?.array?.count == 2)
    let (_, merged, _) = try await h.call("POST", "/api/import", body: JSONValue.encode(try #require(backup)), contentType: "application/json")
    #expect(merged?["added"]?.int == 0)
    #expect(try await h.call("POST", "/api/import", json: .object(["schema": .string("other")])).0 == 400)

    let (s3, spec, _) = try await h.call("GET", "/api/openapi.json")
    #expect(s3 == 200 && spec?["openapi"]?.string == "3.1.0")

    // The changes are in the store the app shows.
    let parts = try h.container.mainContext.fetch(FetchDescriptor<Part>())
    #expect(parts.first { $0.uid == id }?.qty == 10)

    #expect(try await h.call("DELETE", "/api/parts/\(id)").0 == 200)
    #expect(try await h.call("GET", "/api/parts/\(id)").0 == 404)
}

@MainActor @Test func identifyEndToEnd() async throws {
    let h = try await APIHarness()
    defer { h.server.stop() }
    let png = blankPNG()
    let (s1, raw, _) = try await h.call("POST", "/api/identify", body: png, contentType: "image/png")
    #expect(s1 == 200 && raw?["candidates"]?.array != nil)
    let (s2, _, _) = try await h.call("POST", "/api/identify", json: .object(["image": .string(png.base64EncodedString())]))
    #expect(s2 == 200)
    let form = "--B\r\nContent-Disposition: form-data; name=\"image\"; filename=\"x.png\"\r\nContent-Type: image/png\r\n\r\n"
    var body = Data(form.utf8); body.append(png); body.append(Data("\r\n--B--\r\n".utf8))
    #expect(try await h.call("POST", "/api/identify", body: body, contentType: "multipart/form-data; boundary=B").0 == 200)
    #expect(try await h.call("POST", "/api/identify", body: Data("not an image".utf8), contentType: "image/png").0 == 415)
}

@MainActor @Test func mcpEndToEnd() async throws {
    let h = try await APIHarness()
    defer { h.server.stop() }
    #expect(try await h.call("POST", "/mcp", json: .object([:]), auth: false).0 == 401)

    let (initJ, initRes) = try await h.rpc("initialize", .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                                                                    "clientInfo": .object(["name": .string("test"), "version": .string("1")])]))
    let sid = try #require(initRes.value(forHTTPHeaderField: "Mcp-Session-Id"))
    #expect(initJ?["result"]?["protocolVersion"]?.string == "2025-06-18")

    var noteReq = URLRequest(url: URL(string: "http://127.0.0.1:\(h.port)/mcp")!)
    noteReq.httpMethod = "POST"
    noteReq.setValue("Bearer \(h.token)", forHTTPHeaderField: "Authorization")
    noteReq.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
    noteReq.httpBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
    let (_, noteRes) = try await URLSession.shared.data(for: noteReq)
    #expect((noteRes as? HTTPURLResponse)?.statusCode == 202)

    let (list, _) = try await h.rpc("tools/list", id: 2, session: sid)
    let names = Set(list?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? [])
    #expect(names == ["search_parts", "get_part", "add_part", "update_part", "adjust_stock", "set_stock", "delete_part", "list_locations",
                      "add_location", "list_projects", "get_project", "supplier_lookup", "identify_photo", "low_stock"])

    func tool(_ name: String, _ args: [String: JSONValue], id: Int) async throws -> (String, Bool) {
        let (j, _) = try await h.rpc("tools/call", .object(["name": .string(name), "arguments": .object(args)]), id: id, session: sid)
        let r = j?["result"]
        return (r?["content"]?.array?.first?["text"]?.string ?? "", r?["isError"]?.bool ?? true)
    }
    let (added, addErr) = try await tool("add_part", ["mpn": .string("NE555P"), "qty": .number(7), "location": .string("Bin 1"), "lookup": .bool(true)], id: 3)
    #expect(!addErr && added.contains("Added NE555P"))
    #expect(added.contains("No supplier keys"))
    let partID = try #require(Inventory.allParts(h.container.mainContext).first?.uid)

    let (search, _) = try await tool("search_parts", ["query": .string("ne555")], id: 4)
    #expect(search.hasPrefix("1 part matching") && search.contains(partID))
    let (adj, _) = try await tool("adjust_stock", ["id": .string(partID), "delta": .number(-3), "note": .string("timer kit")], id: 5)
    #expect(adj.contains("now 4"))
    let (setS, _) = try await tool("set_stock", ["id": .string(partID), "qty": .number(2)], id: 6)
    #expect(setS.contains("set to 2"))
    _ = try await tool("update_part", ["id": .string(partID), "lowStock": .number(3)], id: 7)
    let (low, _) = try await tool("low_stock", [:], id: 8)
    #expect(low.hasPrefix("1 part low on stock"))
    let (locs, _) = try await tool("list_locations", [:], id: 9)
    #expect(locs.hasPrefix("1 location"))
    let (lookup, lookupErr) = try await tool("supplier_lookup", ["query": .string("NE555P")], id: 10)
    #expect(lookupErr && lookup.contains("No supplier keys"))
    let (noDelete, noDeleteErr) = try await tool("delete_part", ["id": .string(partID)], id: 11)
    #expect(noDeleteErr && noDelete.contains("confirm"))
    let (missing, missingErr) = try await tool("get_part", ["id": .string("nope")], id: 12)
    #expect(missingErr && missing.contains("No part"))
    let (deleted, deleteErr) = try await tool("delete_part", ["id": .string(partID), "confirm": .bool(true)], id: 13)
    #expect(!deleteErr && deleted.contains("Deleted NE555P"))
    #expect(Inventory.allParts(h.container.mainContext).isEmpty)
}
