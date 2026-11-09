import Foundation
import PartsKit

// The REST API under /api and the MCP tools, as the app serves them (App/API/APIRoutes.swift), over PartsServer.

extension PartsServer {
    private typealias Route = (method: String, pattern: RoutePattern, run: @Sendable (isolated PartsServer, HTTPRequest, [String: String]) async throws -> HTTPResponse)

    static let identifyUnsupported = "Identifying a part from a photo needs Apple’s Vision framework: use the Mac or iPhone app for that."

    /// The app's OpenAPI document, retitled for partsd and without /api/identify.
    static let openAPI: Data = {
        guard case .object(var doc) = (try? JSONDecoder().decode(JSONValue.self, from: Data(InventoryCatalog.openAPI.utf8))) ?? .null else { return Data() }
        if case .object(var info) = doc["info"] ?? .null {
            info["title"] = .string("e-Parts Inventory Manager (partsd)")
            info["version"] = .string(version)
            info["description"] = .string("The parts inventory served by partsd, the headless server. Parts have the same shape as the web version's backup file, plus locationPath, photoCount, isLow and summary. Every endpoint except /api/health needs Authorization: Bearer <token> (partsd prints where its token is kept). The same data is available as MCP tools at /mcp. Photo identification needs the Mac or iPhone app.")
            doc["info"] = .object(info)
        }
        if case .object(var paths) = doc["paths"] ?? .null { paths["/api/identify"] = nil; doc["paths"] = .object(paths) }
        return JSONValue.encode(.object(doc))
    }()

    private static let routes: [Route] = [
        ("GET", RoutePattern("/api/health"), { s, _, _ in
            .json(.object(["ok": .bool(true), "app": .string("e-Parts Inventory Manager (partsd)"), "version": .string(PartsServer.version),
                           "parts": .number(Double(s.partCount))]))
        }),
        ("GET", RoutePattern("/api/openapi.json"), { _, _, _ in
            HTTPResponse(status: 200, headers: [("Content-Type", "application/json; charset=utf-8")], body: PartsServer.openAPI)
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
        ("GET", RoutePattern("/api/locations"), { s, _, _ in .json(.object(["locations": .array(s.locations().map { s.locationJSON($0) })])) }),
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
        ("POST", RoutePattern("/api/identify"), { _, _, _ in throw PartsServer.fail(501, PartsServer.identifyUnsupported) }),
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
        default:
            throw Self.fail(404, "Unknown tool \(name).")
        }
    }
}

/// The inventory's MCP tools as partsd serves them: the app's, less identify_photo.
public struct PartsServerTools: MCPToolProvider {
    public let server: PartsServer
    public init(server: PartsServer) { self.server = server }

    static let list = InventoryCatalog.tools.filter { $0.name != "identify_photo" }

    public func tools() async -> [MCPTool] { Self.list }

    public func call(_ name: String, arguments a: [String: JSONValue]) async -> MCPToolResult {
        do { return try await server.runTool(name, a) }
        catch let f as PartsServer.Failure { return .failure(f.message) }
        catch { return .failure(error.localizedDescription) }
    }
}

extension PartsServer {
    /// The whole front door: Origin check, token, /mcp and /api.
    public func gate(token: @escaping @Sendable () -> String, extraOriginHosts: Set<String> = []) -> APIGate {
        let mcp = MCPEndpoint(name: "parts-inventory", version: Self.version, instructions: InventoryCatalog.instructions, provider: PartsServerTools(server: self))
        return APIGate(token: token, mcp: mcp, extraOriginHosts: extraOriginHosts) { [self] req in await self.handle(req) }
    }
}
