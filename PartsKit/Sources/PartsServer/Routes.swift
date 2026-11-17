import Foundation
import PartsKit

// The REST API under /api and the MCP tools, as the app serves them (App/API/APIRoutes.swift), over PartsServer.

extension PartsServer {
    private typealias Route = (method: String, pattern: RoutePattern, run: @Sendable (isolated PartsServer, HTTPRequest, [String: String]) async throws -> HTTPResponse)

    static let identifyUnsupported = "Identifying photos needs a vision model: start partsd with PARTSD_AI_URL and PARTSD_VISION_MODEL set (see PORTABILITY.md), or use the Mac or iPhone app."

    /// The app's OpenAPI document, retitled for partsd, without /api/identify when there's no vision model.
    static func openAPI(identify: Bool) -> Data {
        guard case .object(var doc) = (try? JSONDecoder().decode(JSONValue.self, from: Data(InventoryCatalog.openAPI.utf8))) ?? .null else { return Data() }
        if case .object(var info) = doc["info"] ?? .null {
            info["title"] = .string("e-Parts Inventory Manager (partsd)")
            info["version"] = .string(version)
            info["description"] = .string("The parts inventory served by partsd, the headless server. Parts have the same shape as the web version's backup file, plus locationPath, photoCount, isLow and summary. Every endpoint except /api/health needs Authorization: Bearer <token> (partsd prints where its token is kept). The same data is available as MCP tools at /mcp. Photo identification needs a vision model configured (PARTSD_AI_URL, PARTSD_VISION_MODEL); the bag-label barcodes and look recognition are the app's alone.")
            doc["info"] = .object(info)
        }
        if case .object(var paths) = doc["paths"] ?? .null {
            if !identify { paths["/api/identify"] = nil }
            for (path, ops) in extraPaths {
                // Beside any operations the app's document already has on the path (GET a photo).
                var merged = paths[path]?.object ?? [:]
                for (k, v) in ops.object ?? [:] { merged[k] = v }
                paths[path] = .object(merged)
            }
            doc["paths"] = .object(paths)
        }
        return JSONValue.encode(.object(doc))
    }

    /// The endpoints only partsd has (its web pages use them): photos, filling in from a supplier, editing locations.
    static let extraPaths: [String: JSONValue] = {
        func op(_ summary: String, _ id: String, body: String? = nil) -> JSONValue {
            var o: [String: JSONValue] = ["summary": .string(summary), "operationId": .string(id),
                                          "responses": .object(["200": .object(["description": .string("The changed part or location as JSON.")])])]
            if let body { o["requestBody"] = .object(["description": .string(body)]) }
            return .object(o)
        }
        return [
            "/api/parts/{uid}/photos": .object(["post": op("Add a photo to a part", "addPhoto", body: "The JPEG or PNG itself, a form upload, or {\"image\": \"<base64>\"}.")]),
            "/api/parts/{uid}/photos/{index}": .object(["delete": op("Remove a part's photo", "deletePhoto")]),
            "/api/parts/{uid}/fill": .object(["post": op("Fill a part's empty fields from Digi-Key and Mouser", "fillPart",
                                                         body: "{\"query\"?: number to look up (default the part's), \"supplier\"?, \"spn\"?: the listing to use (default the best, and its twin at the other supplier)}")]),
            "/api/locations/{id}": .object(["patch": op("Rename, move or annotate a location", "updateLocation", body: "{\"name\"?, \"notes\"?, \"parentId\"?: id or null}"),
                                            "delete": op("Remove a location; its parts and places move up a level", "deleteLocation")]),
        ]
    }()

    private static let routes: [Route] = [
        ("GET", RoutePattern("/api/health"), { s, _, _ in
            .json(.object(["ok": .bool(true), "app": .string("e-Parts Inventory Manager (partsd)"), "version": .string(PartsServer.version),
                           "parts": .number(Double(s.partCount)), "identify": .bool(s.canIdentify)]))
        }),
        ("GET", RoutePattern("/api/openapi.json"), { s, _, _ in
            HTTPResponse(status: 200, headers: [("Content-Type", "application/json; charset=utf-8")], body: PartsServer.openAPI(identify: s.canIdentify))
        }),
        ("GET", RoutePattern("/api/parts"), { s, req, _ in
            let q = req.query
            let page = s.search(q: q["q"] ?? "", category: q["category"] ?? "", location: q["location"] ?? "", lowOnly: q["low"] == "true" || q["low"] == "1",
                                limit: q["limit"].flatMap(Int.init) ?? 100, offset: q["offset"].flatMap(Int.init) ?? 0)
            return .json(.object(["total": .number(Double(page.total)), "parts": .array(page.parts.map { s.partJSON($0) })]))
        }),
        ("POST", RoutePattern("/api/parts"), { s, req, _ in
            let f = try body(req)
            let (p, note) = try await s.create(f, lookup: f["lookup"]?.bool ?? false)
            var o = s.partJSON(p).object ?? [:]
            if note.tried || !note.errors.isEmpty {
                o["lookup"] = .object(["used": .array(note.used.map { InventoryCatalog.productJSON($0) }), "errors": .object(note.errors.mapValues(JSONValue.string))])
            }
            return .json(.object(o), status: 201)
        }),
        ("GET", RoutePattern("/api/parts/{uid}"), { s, _, m in
            let p = s.b.parts[try s.index(of: m["uid"]!)]
            var o = s.partJSON(p).object ?? [:]
            o["history"] = s.history(p.id)
            return .json(.object(o))
        }),
        ("PATCH", RoutePattern("/api/parts/{uid}"), { s, req, m in .json(s.partJSON(try s.update(m["uid"]!, try body(req)))) }),
        ("PUT", RoutePattern("/api/parts/{uid}"), { s, req, m in .json(s.partJSON(try s.update(m["uid"]!, try body(req)))) }),
        ("DELETE", RoutePattern("/api/parts/{uid}"), { s, _, m in
            .json(.object(["deleted": .string(m["uid"]!), "title": .string(try s.delete(m["uid"]!))]))
        }),
        ("POST", RoutePattern("/api/parts/{uid}/stock"), { s, req, m in
            let f = try body(req)
            let (p, changed) = try s.stock(m["uid"]!, delta: f["delta"]?.int, set: f["set"]?.int, note: f["note"]?.string ?? "")
            return .json(.object(["id": .string(p.id), "qty": .number(p.qty), "changed": .number(Double(changed))]))
        }),
        ("GET", RoutePattern("/api/parts/{uid}/photos/{index}"), { s, _, m in
            guard let i = Int(m["index"]!) else { throw PartsServer.fail(400, "The photo index is a number from 0.") }
            let (d, type) = try s.photo(m["uid"]!, index: i)
            return HTTPResponse(status: 200, headers: [("Content-Type", type)], body: d)
        }),
        ("POST", RoutePattern("/api/parts/{uid}/photos"), { s, req, m in .json(s.partJSON(try s.addPhoto(m["uid"]!, try imageBody(req))), status: 201) }),
        ("DELETE", RoutePattern("/api/parts/{uid}/photos/{index}"), { s, _, m in
            guard let i = Int(m["index"]!) else { throw PartsServer.fail(400, "The photo index is a number from 0.") }
            return .json(s.partJSON(try s.deletePhoto(m["uid"]!, index: i)))
        }),
        ("POST", RoutePattern("/api/parts/{uid}/fill"), { s, req, m in
            let f = try body(req)
            let (p, used) = try await s.fill(m["uid"]!, query: f["query"]?.string, supplier: f["supplier"]?.string, spn: f["spn"]?.string)
            var o = s.partJSON(p).object ?? [:]
            o["filledFrom"] = .array(used.map { InventoryCatalog.productJSON($0) })
            return .json(.object(o))
        }),
        ("GET", RoutePattern("/api/locations"), { s, _, _ in .json(.object(["locations": .array(s.locations().map { s.locationJSON($0) })])) }),
        ("PATCH", RoutePattern("/api/locations/{id}"), { s, req, m in .json(s.locationJSON(try s.updateLocation(m["id"]!, try body(req)))) }),
        ("DELETE", RoutePattern("/api/locations/{id}"), { s, _, m in
            let r = try s.deleteLocation(m["id"]!)
            return .json(.object(["deleted": .string(m["id"]!), "path": .string(r.name), "partsMoved": .number(Double(r.moved))]))
        }),
        ("POST", RoutePattern("/api/locations"), { s, req, _ in
            guard let path = try body(req)["path"]?.string else { throw PartsServer.fail(400, "Send {\"path\": \"Cabinet A / Drawer 3\"}.") }
            return .json(s.locationJSON(try s.addLocation(path)), status: 201)
        }),
        ("GET", RoutePattern("/api/projects"), { s, _, _ in .json(.object(["projects": .array(s.projects().map { s.projectJSON($0, lines: false) })])) }),
        ("GET", RoutePattern("/api/projects/{uid}"), { s, _, m in
            guard let pr = s.projects().first(where: { $0.id == m["uid"]! }) else { throw PartsServer.fail(404, "No project with id \(m["uid"]!).") }
            return .json(s.projectJSON(pr, lines: true))
        }),
        ("GET", RoutePattern("/api/lookup"), { s, req, _ in .json(InventoryCatalog.lookupJSON(try await s.supplierLookup(req.query["q"] ?? ""))) }),
        ("POST", RoutePattern("/api/identify"), { s, req, _ in .json(try await s.identify(try imageBody(req))) }),
        ("GET", RoutePattern("/api/export"), { s, req, _ in
            HTTPResponse(status: 200, headers: [("Content-Type", "application/json; charset=utf-8")], body: try s.backup(photos: req.query["photos"] == "true").encoded())
        }),
        ("POST", RoutePattern("/api/import"), { s, req, _ in
            let r = try s.importBackup(req.body)
            return .json(.object(["added": .number(Double(r.added)), "updated": .number(Double(r.updated)), "kept": .number(Double(r.kept)),
                                  "photos": .number(Double(r.photos)), "warnings": .array(r.warnings.map(JSONValue.string))]))
        }),
    ]

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        var allowed: [String] = []
        for r in Self.routes {
            guard let m = r.pattern.match(req.path) else { continue }
            guard r.method == req.method || (r.method == "GET" && req.method == "HEAD") else { allowed.append(r.method); continue }
            do {
                var res = try await r.run(self, req, m)
                if req.method == "HEAD" { res.body = Data() }
                return res
            } catch let f as Failure {
                return .error(f.status, f.message)
            } catch {
                return .error(500, error.localizedDescription)
            }
        }
        if !allowed.isEmpty { return HTTPResponse(status: 405, headers: [("Allow", allowed.joined(separator: ", "))], body: JSONValue.encode(.object(["error": .string("Use \(allowed.joined(separator: " or ")) here.")]))) }
        return .error(404, "No such endpoint: \(req.method) \(req.path). See /api/openapi.json.")
    }

    private static func body(_ req: HTTPRequest) throws -> [String: JSONValue] {
        if req.body.isEmpty { return [:] }
        guard let o = req.json?.object else { throw PartsServer.fail(400, "The body should be a JSON object.") }
        return o
    }

    /// An image sent as the body itself, as multipart/form-data, or as JSON {"image": "<base64>"} (as the app takes it).
    private static func imageBody(_ req: HTTPRequest) throws -> Data {
        let type = req.header("content-type")?.lowercased() ?? ""
        if type.hasPrefix("multipart/form-data") {
            guard let f = Multipart.firstFile(req.body, contentType: req.header("content-type") ?? "") else { throw PartsServer.fail(400, "No file in the form.") }
            return f.data
        }
        if type.hasPrefix("application/json") || req.body.first == UInt8(ascii: "{") {
            guard let d = req.json?["image"]?.string.flatMap(decodeBase64) else {
                throw PartsServer.fail(400, "Send {\"image\": \"<base64 JPEG or PNG>\"}, or the image itself as the body.")
            }
            return d
        }
        guard !req.body.isEmpty else { throw PartsServer.fail(400, "Send a photo: the image as the body, a form upload, or {\"image\": \"<base64>\"}.") }
        return req.body
    }

    static func decodeBase64(_ s: String) -> Data? {
        Data(base64Encoded: s.replacingOccurrences(of: "^data:[^,]*,", with: "", options: .regularExpression), options: .ignoreUnknownCharacters)
    }

    // MARK: MCP tools

    func runTool(_ name: String, _ a: [String: JSONValue]) async throws -> MCPToolResult {
        func id() throws -> String {
            guard let s = a["id"]?.string, !s.isEmpty else { throw Self.fail(400, "id is required.") }
            return s
        }
        switch name {
        case "search_parts", "low_stock":
            let low = name == "low_stock" || a["low_only"]?.bool == true
            let page = search(q: a["query"]?.string ?? "", category: a["category"]?.string ?? "", location: a["location"]?.string ?? "",
                              lowOnly: low, limit: a["limit"]?.int ?? (name == "low_stock" ? 200 : 25))
            let what = low ? "low on stock" : "matching"
            let summary = page.total == 0 ? "No parts \(what)." : "\(page.total) part\(page.total == 1 ? "" : "s") \(what)" + (page.parts.count < page.total ? ", showing \(page.parts.count)." : ".")
            return MCPToolResult(summary: summary, data: .array(page.parts.map { partJSON($0, brief: true) }))
        case "get_part":
            let p = b.parts[try index(of: id())]
            var o = partJSON(p).object ?? [:]
            o["history"] = history(p.id, limit: 10)
            let at = path(p.locationId)
            return MCPToolResult(summary: "\(Self.title(p)): \(Int(p.qty)) in stock" + (at.isEmpty ? "" : " at \(at)") + ".", data: .object(o))
        case "add_part":
            let mpn = a["mpn"]?.string ?? ""
            let (p, note) = try await create(a, lookup: a["lookup"]?.bool ?? !mpn.isEmpty)
            var s = "Added \(Self.title(p)) (id \(p.id)) with \(Int(p.qty)) in stock."
            if !note.used.isEmpty { s += " Filled in from " + note.used.map(\.supplierName).joined(separator: " and ") + "." }
            else if note.tried { s += " Digi-Key and Mouser had no exact match." }
            if !note.errors.isEmpty { s += " Lookup problems: " + note.errors.map { "\($0.key): \($0.value)" }.joined(separator: "; ") }
            return MCPToolResult(summary: s, data: partJSON(p))
        case "update_part":
            var f = a; f["id"] = nil; f["qty"] = nil
            let p = try update(id(), f)
            return MCPToolResult(summary: "Updated \(Self.title(p)).", data: partJSON(p))
        case "adjust_stock":
            guard let d = a["delta"]?.int else { throw Self.fail(400, "delta is required.") }
            let (p, changed) = try stock(id(), delta: d, set: nil, note: a["note"]?.string ?? "")
            return MCPToolResult(summary: "\(Self.title(p)): \(changed >= 0 ? "+" : "")\(changed), now \(Int(p.qty)).", data: partJSON(p, brief: true))
        case "set_stock":
            guard let q = a["qty"]?.int else { throw Self.fail(400, "qty is required.") }
            let (p, changed) = try stock(id(), delta: nil, set: q, note: a["note"]?.string ?? "")
            return MCPToolResult(summary: "\(Self.title(p)): set to \(Int(p.qty)) (\(changed >= 0 ? "+" : "")\(changed)).", data: partJSON(p, brief: true))
        case "delete_part":
            guard a["confirm"]?.bool == true else { return .failure("Not deleted: set confirm to true (after checking with the user).") }
            let title = try delete(id())
            return MCPToolResult(summary: "Deleted \(title).")
        case "list_locations":
            let ls = locations()
            return MCPToolResult(summary: "\(ls.count) location\(ls.count == 1 ? "" : "s").", data: .array(ls.map { locationJSON($0) }))
        case "add_location":
            guard let p = a["path"]?.string else { throw Self.fail(400, "path is required.") }
            let l = try addLocation(p)
            return MCPToolResult(summary: "Location \(path(l.id)) (id \(l.id)).", data: locationJSON(l))
        case "list_projects":
            let ps = projects()
            return MCPToolResult(summary: "\(ps.count) project\(ps.count == 1 ? "" : "s").", data: .array(ps.map { projectJSON($0, lines: false) }))
        case "get_project":
            let pid = try id()
            guard let pr = projects().first(where: { $0.id == pid }) else { throw Self.fail(404, "No project with id \(pid).") }
            let j = projectJSON(pr, lines: true)
            return MCPToolResult(summary: "\(pr.name): \(pr.lines.count) lines, enough for \(j["canBuild"]?.int ?? 0) board(s).", data: j)
        case "supplier_lookup":
            let r = try await supplierLookup(a["query"]?.string ?? "")
            let limit = a["limit"]?.int ?? 10
            var s = "\(r.products.count) listing\(r.products.count == 1 ? "" : "s") at Digi-Key and Mouser" + (r.products.count > limit ? ", showing \(limit)." : ".")
            if !r.errors.isEmpty { s += " Problems: " + r.errors.map { "\($0.key): \($0.value)" }.joined(separator: "; ") }
            return MCPToolResult(summary: s, data: InventoryCatalog.lookupJSON(r, limit: limit))
        case "identify_photo" where canIdentify:
            guard let d = a["image_base64"]?.string.flatMap(Self.decodeBase64) else { throw Self.fail(400, "image_base64 should be a base64 JPEG or PNG.") }
            let j = try await identify(d)
            let top = j["candidates"]?.array?.first
            let s = top.map { "Most likely \($0["name"]?.string ?? "?") (\($0["confidence"]?.string ?? ""))." } ?? "Nothing recognised."
            return MCPToolResult(summary: s, data: j)
        default:
            throw Self.fail(404, "Unknown tool \(name).")
        }
    }
}

/// The inventory's MCP tools as partsd serves them: the app's, less identify_photo when there's no vision model.
public struct PartsServerTools: MCPToolProvider {
    public let server: PartsServer
    public init(server: PartsServer) { self.server = server }

    static let withoutIdentify = InventoryCatalog.tools.filter { $0.name != "identify_photo" }

    public func tools() async -> [MCPTool] { await server.canIdentify ? InventoryCatalog.tools : Self.withoutIdentify }

    public func call(_ name: String, arguments a: [String: JSONValue]) async -> MCPToolResult {
        do { return try await server.runTool(name, a) }
        catch let f as PartsServer.Failure { return .failure(f.message) }
        catch { return .failure(error.localizedDescription) }
    }
}

extension PartsServer {
    /// The whole front door: Origin check, token, /mcp and /api, and the web pages everywhere else when there are some.
    public func gate(token: @escaping @Sendable () -> String, extraOriginHosts: Set<String> = [], site: WebSite? = nil) -> APIGate {
        let mcp = MCPEndpoint(name: "parts-inventory", version: Self.version, instructions: InventoryCatalog.instructions, provider: PartsServerTools(server: self))
        return APIGate(token: token, mcp: mcp, extraOriginHosts: extraOriginHosts, site: site.map { w in { @Sendable req in w.handle(req) } }) { [self] req in await self.handle(req) }
    }
}
