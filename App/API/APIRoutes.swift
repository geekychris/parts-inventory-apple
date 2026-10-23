import Foundation
import PartsKit

// The REST API under /api and the MCP tools, both over InventoryAPI.

extension InventoryAPI {
    private typealias Route = (method: String, pattern: RoutePattern, run: @MainActor (InventoryAPI, HTTPRequest, [String: String]) async throws -> HTTPResponse)

    private static let routes: [Route] = [
        ("GET", RoutePattern("/api/health"), { _, _, _ in
            .json(.object(["ok": .bool(true), "app": .string("e-Parts Inventory Manager"), "version": .string(APIService.appVersion)]))
        }),
        ("GET", RoutePattern("/api/openapi.json"), { _, _, _ in
            HTTPResponse(status: 200, headers: [("Content-Type", "application/json; charset=utf-8")], body: Data(OpenAPI.document.utf8))
        }),
        ("GET", RoutePattern("/api/parts"), { api, req, _ in
            let q = req.query
            let page = api.search(q: q["q"] ?? "", category: q["category"] ?? "", location: q["location"] ?? "", lowOnly: q["low"] == "true" || q["low"] == "1",
                                  limit: q["limit"].flatMap(Int.init) ?? 100, offset: q["offset"].flatMap(Int.init) ?? 0)
            return .json(.object(["total": .number(Double(page.total)), "parts": .array(page.parts.map { api.partJSON($0) })]))
        }),
        ("POST", RoutePattern("/api/parts"), { api, req, _ in
            let f = try body(req)
            let (p, note) = try await api.create(f, lookup: f["lookup"]?.bool ?? false)
            var o = api.partJSON(p).object ?? [:]
            if note.tried || !note.errors.isEmpty {
                o["lookup"] = .object(["used": .array(note.used.map { InventoryAPI.productJSON($0) }), "errors": .object(note.errors.mapValues(JSONValue.string))])
            }
            return .json(.object(o), status: 201)
        }),
        ("GET", RoutePattern("/api/parts/{uid}"), { api, req, m in
            let p = try api.part(m["uid"]!)
            var o = api.partJSON(p).object ?? [:]
            o["history"] = api.history(p)
            return .json(.object(o))
        }),
        ("PATCH", RoutePattern("/api/parts/{uid}"), { api, req, m in .json(api.partJSON(try api.update(m["uid"]!, try body(req)))) }),
        ("PUT", RoutePattern("/api/parts/{uid}"), { api, req, m in .json(api.partJSON(try api.update(m["uid"]!, try body(req)))) }),
        ("DELETE", RoutePattern("/api/parts/{uid}"), { api, _, m in
            .json(.object(["deleted": .string(m["uid"]!), "title": .string(try api.delete(m["uid"]!))]))
        }),
        ("POST", RoutePattern("/api/parts/{uid}/stock"), { api, req, m in
            let f = try body(req)
            let (p, changed) = try api.stock(m["uid"]!, delta: f["delta"]?.int, set: f["set"]?.int, note: f["note"]?.string ?? "")
            return .json(.object(["id": .string(p.uid), "qty": .number(Double(p.qty)), "changed": .number(Double(changed))]))
        }),
        ("GET", RoutePattern("/api/parts/{uid}/photos/{index}"), { api, _, m in
            guard let i = Int(m["index"]!) else { throw InventoryAPI.fail(400, "The photo index is a number from 0.") }
            let (d, type) = try api.photo(m["uid"]!, index: i)
            return HTTPResponse(status: 200, headers: [("Content-Type", type)], body: d)
        }),
        ("GET", RoutePattern("/api/locations"), { api, _, _ in .json(.object(["locations": .array(api.locations().map { api.locationJSON($0) })])) }),
        ("POST", RoutePattern("/api/locations"), { api, req, _ in
            guard let path = try body(req)["path"]?.string else { throw InventoryAPI.fail(400, "Send {\"path\": \"Cabinet A / Drawer 3\"}.") }
            return .json(api.locationJSON(try api.addLocation(path)), status: 201)
        }),
        ("GET", RoutePattern("/api/projects"), { api, _, _ in .json(.object(["projects": .array(api.projects().map { api.projectJSON($0, lines: false) })])) }),
        ("GET", RoutePattern("/api/projects/{uid}"), { api, _, m in
            guard let pr = api.projects().first(where: { $0.uid == m["uid"]! }) else { throw InventoryAPI.fail(404, "No project with id \(m["uid"]!).") }
            return .json(api.projectJSON(pr, lines: true))
        }),
        ("GET", RoutePattern("/api/lookup"), { api, req, _ in .json(InventoryAPI.lookupJSON(try await api.supplierLookup(req.query["q"] ?? ""))) }),
        ("POST", RoutePattern("/api/identify"), { api, req, _ in .json(try await api.identify(try imageBody(req))) }),
        ("GET", RoutePattern("/api/export"), { api, req, _ in
            HTTPResponse(status: 200, headers: [("Content-Type", "application/json; charset=utf-8")], body: try api.export(photos: req.query["photos"] == "true"))
        }),
        ("POST", RoutePattern("/api/import"), { api, req, _ in
            let r = try api.importBackup(req.body)
            return .json(.object(["added": .number(Double(r.added)), "updated": .number(Double(r.updated)), "kept": .number(Double(r.kept)),
                                  "photos": .number(Double(r.photos)), "warnings": .array(r.warnings.map(JSONValue.string))]))
        }),
    ]

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
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
        guard let o = req.json?.object else { throw InventoryAPI.fail(400, "The body should be a JSON object.") }
        return o
    }

    /// An image sent as the body itself, as multipart/form-data, or as JSON {"image": "<base64>"}.
    private static func imageBody(_ req: HTTPRequest) throws -> Data {
        let type = req.header("content-type")?.lowercased() ?? ""
        if type.hasPrefix("multipart/form-data") {
            guard let f = Multipart.firstFile(req.body, contentType: req.header("content-type") ?? "") else { throw InventoryAPI.fail(400, "No file in the form.") }
            return f.data
        }
        if type.hasPrefix("application/json") || req.body.first == UInt8(ascii: "{") {
            guard let b64 = req.json?["image"]?.string,
                  let d = Data(base64Encoded: b64.replacingOccurrences(of: "^data:[^,]*,", with: "", options: .regularExpression), options: .ignoreUnknownCharacters)
            else { throw InventoryAPI.fail(400, "Send {\"image\": \"<base64 JPEG or PNG>\"}, or the image itself as the body.") }
            return d
        }
        guard !req.body.isEmpty else { throw InventoryAPI.fail(400, "Send a photo: the image as the body, a form upload, or {\"image\": \"<base64>\"}.") }
        return req.body
    }
}

// MARK: - MCP tools

/// The inventory's tools for MCP clients (Claude Code, Claude Desktop and others).
nonisolated struct InventoryTools: MCPToolProvider {
    let api: InventoryAPI

    func tools() async -> [MCPTool] { Self.list }

    static let list: [MCPTool] = {
        typealias S = JSONSchema
        let fields: [String: JSONValue] = [
            "mpn": S.string("Manufacturer part number"), "manufacturer": S.string("Maker"), "description": S.string("What it is"),
            "category": S.string("Category path, e.g. \"Passives/Resistors\""), "package": S.string("Package, e.g. \"0603\" or \"SOIC-8\""),
            "datasheet": S.string("Datasheet URL"), "notes": S.string("Free text"), "tags": S.strings("Tags"),
            "location": S.string("Storage location path, e.g. \"Cabinet A / Drawer 3\" (made if it doesn't exist)"),
            "lowStock": S.integer("Warn when stock falls to this", minimum: 0),
            "paramsText": S.string("Parameters as text, e.g. \"10k 1% 0603\" or \"100nF 50V X7R\" — parsed into value, tolerance, voltage, package"),
        ]
        return [
            MCPTool(name: "search_parts", title: "Search parts",
                    description: "Search the parts inventory. The query matches part numbers, makers, descriptions, tags and locations, and understands values: \"10k 0603 1%\", \"100nF 50V\", \"cat:caps\", \"loc:drawer 2\", \"tag:smd\", \"mfr:ti\", \"low\". Returns brief parts with their id, stock and location.",
                    inputSchema: S.object(["query": S.string("Search text; empty lists everything"), "category": S.string("Only this category (substring)"),
                                           "location": S.string("Only this location path (substring)"), "low_only": S.boolean("Only parts at or below their low-stock level"),
                                           "limit": S.integer("Most results to return (default 25)", minimum: 1)]), readOnly: true),
            MCPTool(name: "get_part", title: "Get a part", description: "Everything about one part by id: fields, parameters, suppliers with prices, location, photos and recent stock history.",
                    inputSchema: S.object(["id": S.string("Part id (from search_parts)")], required: ["id"]), readOnly: true),
            MCPTool(name: "add_part", title: "Add a part",
                    description: "Add a new part. Set lookup=true to fill empty fields (maker, description, package, datasheet, parameters, supplier numbers and prices) from Digi-Key and Mouser by its part number. Check search_parts first to avoid duplicates — to add stock to an existing part use adjust_stock.",
                    inputSchema: S.object(fields.merging(["qty": S.integer("Starting stock", minimum: 0), "lookup": S.boolean("Fill in from Digi-Key/Mouser (default true when mpn is given)")]) { a, _ in a })),
            MCPTool(name: "update_part", title: "Update a part", description: "Change a part's fields. Only the fields given change; stock changes go through adjust_stock or set_stock.",
                    inputSchema: S.object(fields.merging(["id": S.string("Part id")]) { a, _ in a }, required: ["id"])),
            MCPTool(name: "adjust_stock", title: "Adjust stock", description: "Add to or take from a part's stock (negative to use parts), with a note recorded in its history.",
                    inputSchema: S.object(["id": S.string("Part id"), "delta": S.integer("How many to add (negative to remove)"), "note": S.string("Why, e.g. \"used in the amp build\"")], required: ["id", "delta"])),
            MCPTool(name: "set_stock", title: "Set stock", description: "Set a part's stock to a counted quantity, recorded in its history.",
                    inputSchema: S.object(["id": S.string("Part id"), "qty": S.integer("The counted quantity", minimum: 0), "note": S.string("Why")], required: ["id", "qty"])),
            MCPTool(name: "delete_part", title: "Delete a part", description: "Delete a part and its photos. Irreversible: confirm must be true, and you should ask the user first.",
                    inputSchema: S.object(["id": S.string("Part id"), "confirm": S.boolean("Must be true")], required: ["id", "confirm"]), destructive: true),
            MCPTool(name: "list_locations", title: "List locations", description: "The storage locations (cabinets, drawers, bins) with their paths and how many parts each holds.",
                    inputSchema: S.object([:]), readOnly: true),
            MCPTool(name: "add_location", title: "Add a location", description: "Make a storage location from a path; missing levels are made too.",
                    inputSchema: S.object(["path": S.string("e.g. \"Cabinet A / Drawer 3 / Bin 2\"")], required: ["path"])),
            MCPTool(name: "list_projects", title: "List projects", description: "Projects (bills of materials) with how many boards the stock can build and how many lines are short.",
                    inputSchema: S.object([:]), readOnly: true),
            MCPTool(name: "get_project", title: "Get a project", description: "A project's BOM lines with what each needs, what's in stock, the matched part and where it is.",
                    inputSchema: S.object(["id": S.string("Project id")], required: ["id"]), readOnly: true),
            MCPTool(name: "supplier_lookup", title: "Look up at Digi-Key and Mouser",
                    description: "Look a part number up at Digi-Key and Mouser: makers, descriptions, stock, price breaks, datasheets, packages and parameters. Needs the supplier keys set in the app.",
                    inputSchema: S.object(["query": S.string("Part number (or keywords)"), "limit": S.integer("Most results (default 10)", minimum: 1)], required: ["query"]), readOnly: true),
            MCPTool(name: "identify_photo", title: "Identify a part from a photo",
                    description: "Identify a component from a photo: reads the markings and any bag-label barcode, and recognises boards and modules by how they look. Returns ranked candidates (catalog parts, parts already in the inventory, generic kinds).",
                    inputSchema: S.object(["image_base64": S.string("The photo, JPEG or PNG, base64-encoded")], required: ["image_base64"]), readOnly: true),
            MCPTool(name: "low_stock", title: "Low stock", description: "Parts at or below their low-stock level (or the default level in Settings).",
                    inputSchema: S.object([:]), readOnly: true),
        ]
    }()

    func call(_ name: String, arguments a: [String: JSONValue]) async -> MCPToolResult {
        do { return try await api.runTool(name, a) }
        catch let f as InventoryAPI.Failure { return .failure(f.message) }
        catch { return .failure(error.localizedDescription) }
    }
}

extension InventoryAPI {
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
            let p = try part(id())
            var o = partJSON(p).object ?? [:]
            o["history"] = history(p, limit: 10)
            return MCPToolResult(summary: "\(p.title): \(p.qty) in stock" + (p.location.map { " at \($0.path)" } ?? "") + ".", data: .object(o))
        case "add_part":
            let mpn = a["mpn"]?.string ?? ""
            let (p, note) = try await create(a, lookup: a["lookup"]?.bool ?? !mpn.isEmpty)
            var s = "Added \(p.title) (id \(p.uid)) with \(p.qty) in stock."
            if !note.used.isEmpty { s += " Filled in from " + note.used.map(\.supplierName).joined(separator: " and ") + "." }
            else if note.tried { s += " Digi-Key and Mouser had no exact match." }
            if !note.errors.isEmpty { s += " Lookup problems: " + note.errors.map { "\($0.key): \($0.value)" }.joined(separator: "; ") }
            return MCPToolResult(summary: s, data: partJSON(p))
        case "update_part":
            var f = a; f["id"] = nil; f["qty"] = nil
            let p = try update(id(), f)
            return MCPToolResult(summary: "Updated \(p.title).", data: partJSON(p))
        case "adjust_stock":
            guard let d = a["delta"]?.int else { throw Self.fail(400, "delta is required.") }
            let (p, changed) = try stock(id(), delta: d, set: nil, note: a["note"]?.string ?? "")
            return MCPToolResult(summary: "\(p.title): \(changed >= 0 ? "+" : "")\(changed), now \(p.qty).", data: partJSON(p, brief: true))
        case "set_stock":
            guard let q = a["qty"]?.int else { throw Self.fail(400, "qty is required.") }
            let (p, changed) = try stock(id(), delta: nil, set: q, note: a["note"]?.string ?? "")
            return MCPToolResult(summary: "\(p.title): set to \(p.qty) (\(changed >= 0 ? "+" : "")\(changed)).", data: partJSON(p, brief: true))
        case "delete_part":
            guard a["confirm"]?.bool == true else { return .failure("Not deleted: set confirm to true (after checking with the user).") }
            let title = try delete(id())
            return MCPToolResult(summary: "Deleted \(title).")
        case "list_locations":
            let ls = locations()
            return MCPToolResult(summary: "\(ls.count) location\(ls.count == 1 ? "" : "s").", data: .array(ls.map(locationJSON)))
        case "add_location":
            guard let path = a["path"]?.string else { throw Self.fail(400, "path is required.") }
            let l = try addLocation(path)
            return MCPToolResult(summary: "Location \(l.path) (id \(l.uid)).", data: locationJSON(l))
        case "list_projects":
            let ps = projects()
            return MCPToolResult(summary: "\(ps.count) project\(ps.count == 1 ? "" : "s").", data: .array(ps.map { projectJSON($0, lines: false) }))
        case "get_project":
            let pid = try id()
            guard let pr = projects().first(where: { $0.uid == pid }) else { throw Self.fail(404, "No project with id \(pid).") }
            let j = projectJSON(pr, lines: true)
            return MCPToolResult(summary: "\(pr.name): \(pr.lines.count) lines, enough for \(j["canBuild"]?.int ?? 0) board(s).", data: j)
        case "supplier_lookup":
            let r = try await supplierLookup(a["query"]?.string ?? "")
            let limit = a["limit"]?.int ?? 10
            var s = "\(r.products.count) listing\(r.products.count == 1 ? "" : "s") at Digi-Key and Mouser" + (r.products.count > limit ? ", showing \(limit)." : ".")
            if !r.errors.isEmpty { s += " Problems: " + r.errors.map { "\($0.key): \($0.value)" }.joined(separator: "; ") }
            return MCPToolResult(summary: s, data: Self.lookupJSON(r, limit: limit))
        case "identify_photo":
            guard let b64 = a["image_base64"]?.string,
                  let d = Data(base64Encoded: b64.replacingOccurrences(of: "^data:[^,]*,", with: "", options: .regularExpression), options: .ignoreUnknownCharacters)
            else { throw Self.fail(400, "image_base64 should be a base64 JPEG or PNG.") }
            let j = try await identify(d)
            let top = j["candidates"]?.array?.first
            let s = top.map { "Most likely \($0["name"]?.string ?? "?") (\($0["confidence"]?.string ?? ""))." } ?? "Nothing recognised."
            return MCPToolResult(summary: s, data: j)
        default:
            throw Self.fail(404, "Unknown tool \(name).")
        }
    }
}
