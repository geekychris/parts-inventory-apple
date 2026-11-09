import Foundation

/// What the inventory's API looks like from outside — the MCP tools, the instructions given to MCP clients, the
/// OpenAPI document and the supplier-listing JSON — shared by the app's server and `partsd`, so the two can't drift.
public enum InventoryCatalog {
    public static let instructions = """
        The user's electronic parts inventory (the e-Parts Inventory Manager app). Use search_parts before adding a part, to avoid duplicates; \
        add stock to an existing part with adjust_stock. add_part with lookup fills in details from Digi-Key and Mouser. \
        Locations are paths like "Cabinet A / Drawer 3". Ask before delete_part.
        """

    public static let tools: [MCPTool] = {
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

    public static func productJSON(_ p: SupplierProduct) -> JSONValue {
        .object([
            "supplier": .string(p.supplier), "supplierName": .string(p.supplierName), "spn": .string(p.spn), "mpn": .string(p.mpn),
            "manufacturer": .string(p.manufacturer), "description": .string(p.description), "detail": .string(p.detail),
            "datasheet": .string(p.datasheet), "url": .string(p.url), "image": .string(p.image),
            "stock": p.stock.map { .number(Double($0)) } ?? .null, "package": .string(p.package), "category": .string(p.category), "status": .string(p.status),
            "prices": .array(p.prices.map { .object(["qty": .number(Double($0.qty)), "unit": .number($0.unit), "currency": .string($0.currency)]) }),
            "parameters": .array(p.parameters.map { .object(["name": .string($0.name), "value": .string($0.value)]) }),
        ])
    }

    public static func lookupJSON(_ r: SupplierLookup.Result, limit: Int = 20) -> JSONValue {
        .object(["results": .array(r.products.prefix(limit).map { productJSON($0) }), "count": .number(Double(r.products.count)),
                 "errors": .object(r.errors.mapValues(JSONValue.string))])
    }

    /// The best listing for a number and its twin at the other supplier (same MPN and maker).
    public static func sameMPN(_ products: [SupplierProduct], _ mpn: String) -> [SupplierProduct] {
        func key(_ s: String) -> String { s.uppercased().filter { $0.isLetter || $0.isNumber } }
        let exact = products.filter { key($0.mpn) == key(mpn) }
        guard let best = exact.first ?? products.first else { return [] }
        let twin = products.first { $0.supplier != best.supplier && key($0.mpn) == key(best.mpn) && $0.manufacturer.lowercased().prefix(4) == best.manufacturer.lowercased().prefix(4) }
        return [best] + (twin.map { [$0] } ?? [])
    }

    public static func candidateJSON(_ c: Candidate) -> JSONValue {
        var o: [String: JSONValue] = ["score": .number((c.score * 100).rounded() / 100), "confidence": .string(c.confidence),
                                      "byLook": .bool(c.byLook), "reasons": .array(c.reasons.map(JSONValue.string))]
        switch c.source {
        case .catalog(let e):
            o["kind"] = .string("catalog"); o["name"] = .string(e.displayName); o["mpn"] = .string(e.mpn); o["manufacturer"] = .string(e.mfr)
            o["description"] = .string(e.desc); o["category"] = .string(e.cat); o["datasheet"] = .string(e.ds ?? "")
        case .inventory(let r):
            o["kind"] = .string("inventory"); o["partId"] = .string(r.id); o["mpn"] = .string(r.mpn); o["name"] = .string(r.mpn)
        case .generic(let g):
            o["kind"] = .string("generic"); o["name"] = .string(g.name); o["category"] = .string(g.cat)
        case .unknown(let t):
            o["kind"] = .string("unknown"); o["name"] = .string(t); o["mpn"] = .string(t)
        case .reading(let r):
            o["kind"] = .string("reading"); o["name"] = .string(r.mpn); o["mpn"] = .string(r.mpn); o["manufacturer"] = .string(r.manufacturer)
            o["description"] = .string(r.description); o["category"] = .string(r.category)
        }
        return .object(o)
    }

    /// GET /api/openapi.json.
    public static let openAPI = #"""
{
  "openapi": "3.1.0",
  "info": {
    "title": "e-Parts Inventory Manager",
    "version": "1",
    "description": "The parts inventory in the e-Parts Inventory Manager app, served by the app itself while it runs (Settings › API & MCP). Parts have the same shape as the web version's backup file, plus locationPath, photoCount, isLow and summary. Every endpoint except /api/health needs Authorization: Bearer <token>. The same data is available as MCP tools at /mcp."
  },
  "servers": [{ "url": "http://127.0.0.1:8765" }],
  "security": [{ "bearer": [] }],
  "components": {
    "securitySchemes": { "bearer": { "type": "http", "scheme": "bearer" } },
    "schemas": {
      "Error": { "type": "object", "properties": { "error": { "type": "string" } }, "required": ["error"] },
      "PartParams": {
        "type": "object",
        "description": "Parsed parameters. value is in base units (ohms, farads, henries).",
        "properties": {
          "kind": { "type": "string", "description": "R, C, L, D, Q, U, LED…" },
          "value": { "type": "number" }, "tol": { "type": "number", "description": "Percent" },
          "voltage": { "type": "number" }, "power": { "type": "number" }, "dielectric": { "type": "string" }, "pkg": { "type": "string" }
        }
      },
      "SupplierEntry": {
        "type": "object",
        "properties": {
          "supplier": { "type": "string", "description": "digikey, mouser, lcsc, …" }, "pn": { "type": "string" },
          "breaks": { "type": "array", "items": { "type": "object", "properties": { "qty": { "type": "number" }, "unit": { "type": "number" } } } },
          "currency": { "type": "string" }, "stock": { "type": "number" }, "url": { "type": "string" }
        },
        "required": ["supplier", "pn"]
      },
      "Part": {
        "type": "object",
        "properties": {
          "id": { "type": "string" }, "mpn": { "type": "string" }, "manufacturer": { "type": "string" }, "description": { "type": "string" },
          "category": { "type": "string" }, "package": { "type": "string" }, "params": { "$ref": "#/components/schemas/PartParams" },
          "qty": { "type": "number" }, "locationId": { "type": ["string", "null"] }, "locationPath": { "type": "string" },
          "suppliers": { "type": "array", "items": { "$ref": "#/components/schemas/SupplierEntry" } },
          "datasheet": { "type": "string" }, "image": { "type": "string" }, "notes": { "type": "string" },
          "photoIds": { "type": "array", "items": { "type": "string" } }, "photoCount": { "type": "number" },
          "lowStock": { "type": ["number", "null"] }, "isLow": { "type": "boolean" }, "tags": { "type": "array", "items": { "type": "string" } },
          "summary": { "type": "string" }, "created": { "type": "number", "description": "ms since 1970" }, "updated": { "type": "number" }
        }
      },
      "PartFields": {
        "type": "object",
        "description": "Fields to set. Missing keys are left alone.",
        "properties": {
          "mpn": { "type": "string" }, "manufacturer": { "type": "string" }, "description": { "type": "string" }, "category": { "type": "string" },
          "package": { "type": "string" }, "datasheet": { "type": "string" }, "image": { "type": "string" }, "notes": { "type": "string" },
          "tags": { "oneOf": [{ "type": "array", "items": { "type": "string" } }, { "type": "string" }] },
          "lowStock": { "type": ["integer", "null"] }, "params": { "$ref": "#/components/schemas/PartParams" },
          "paramsText": { "type": "string", "description": "e.g. \"10k 1% 0603\"; parsed into params" },
          "suppliers": { "type": "array", "items": { "$ref": "#/components/schemas/SupplierEntry" } },
          "location": { "type": "string", "description": "A path like \"Cabinet A / Drawer 3\"; made if missing" },
          "locationId": { "type": ["string", "null"] }
        }
      },
      "Location": {
        "type": "object",
        "properties": { "id": { "type": "string" }, "parentId": { "type": ["string", "null"] }, "name": { "type": "string" }, "path": { "type": "string" },
                        "notes": { "type": "string" }, "parts": { "type": "number" }, "partsBelow": { "type": "number" } }
      },
      "SupplierProduct": {
        "type": "object",
        "properties": {
          "supplier": { "type": "string" }, "supplierName": { "type": "string" }, "spn": { "type": "string" }, "mpn": { "type": "string" },
          "manufacturer": { "type": "string" }, "description": { "type": "string" }, "detail": { "type": "string" }, "datasheet": { "type": "string" },
          "url": { "type": "string" }, "image": { "type": "string" }, "stock": { "type": ["number", "null"] }, "package": { "type": "string" },
          "category": { "type": "string" }, "status": { "type": "string" },
          "prices": { "type": "array", "items": { "type": "object", "properties": { "qty": { "type": "number" }, "unit": { "type": "number" }, "currency": { "type": "string" } } } },
          "parameters": { "type": "array", "items": { "type": "object", "properties": { "name": { "type": "string" }, "value": { "type": "string" } } } }
        }
      }
    },
    "responses": {
      "Error": { "description": "Something went wrong", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Error" } } } }
    },
    "parameters": {
      "uid": { "name": "uid", "in": "path", "required": true, "schema": { "type": "string" } }
    }
  },
  "paths": {
    "/api/health": {
      "get": { "summary": "Is the server up?", "security": [], "responses": { "200": { "description": "OK" } } }
    },
    "/api/openapi.json": { "get": { "summary": "This document", "responses": { "200": { "description": "OpenAPI 3.1" } } } },
    "/api/parts": {
      "get": {
        "summary": "Search parts",
        "parameters": [
          { "name": "q", "in": "query", "schema": { "type": "string" }, "description": "Parametric search: \"10k 0603 1%\", \"cat:caps\", \"loc:drawer\", \"tag:x\", \"mfr:ti\", \"low\"" },
          { "name": "category", "in": "query", "schema": { "type": "string" } },
          { "name": "location", "in": "query", "schema": { "type": "string" } },
          { "name": "low", "in": "query", "schema": { "type": "boolean" } },
          { "name": "limit", "in": "query", "schema": { "type": "integer", "default": 100, "maximum": 1000 } },
          { "name": "offset", "in": "query", "schema": { "type": "integer", "default": 0 } }
        ],
        "responses": { "200": { "description": "Parts", "content": { "application/json": { "schema": { "type": "object", "properties": {
          "total": { "type": "integer" }, "parts": { "type": "array", "items": { "$ref": "#/components/schemas/Part" } } } } } } } }
      },
      "post": {
        "summary": "Add a part",
        "requestBody": { "required": true, "content": { "application/json": { "schema": { "allOf": [{ "$ref": "#/components/schemas/PartFields" }, { "type": "object", "properties": {
          "qty": { "type": "integer", "minimum": 0 }, "lookup": { "type": "boolean", "description": "Fill empty fields from Digi-Key and Mouser by mpn" },
          "photo": { "type": "string", "description": "A photo, base64" }, "reason": { "type": "string" } } }] } } } },
        "responses": { "201": { "description": "The new part (with lookup: the listings used and any errors)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Part" } } } },
                       "400": { "$ref": "#/components/responses/Error" } }
      }
    },
    "/api/parts/{uid}": {
      "parameters": [{ "$ref": "#/components/parameters/uid" }],
      "get": { "summary": "A part, with recent stock history", "responses": { "200": { "description": "The part", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Part" } } } }, "404": { "$ref": "#/components/responses/Error" } } },
      "patch": {
        "summary": "Change a part's fields (qty here sets the count, recorded in history)",
        "requestBody": { "required": true, "content": { "application/json": { "schema": { "allOf": [{ "$ref": "#/components/schemas/PartFields" }, { "type": "object", "properties": { "qty": { "type": "integer" }, "reason": { "type": "string" } } }] } } } },
        "responses": { "200": { "description": "The part", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Part" } } } }, "404": { "$ref": "#/components/responses/Error" } }
      },
      "delete": { "summary": "Delete a part and its photos", "responses": { "200": { "description": "Deleted" }, "404": { "$ref": "#/components/responses/Error" } } }
    },
    "/api/parts/{uid}/stock": {
      "parameters": [{ "$ref": "#/components/parameters/uid" }],
      "post": {
        "summary": "Change stock: {delta} adds or removes, {set} sets a counted quantity",
        "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object", "properties": {
          "delta": { "type": "integer" }, "set": { "type": "integer", "minimum": 0 }, "note": { "type": "string" } } } } } },
        "responses": { "200": { "description": "New quantity", "content": { "application/json": { "schema": { "type": "object", "properties": {
          "id": { "type": "string" }, "qty": { "type": "integer" }, "changed": { "type": "integer" } } } } } }, "400": { "$ref": "#/components/responses/Error" } }
      }
    },
    "/api/parts/{uid}/photos/{index}": {
      "parameters": [{ "$ref": "#/components/parameters/uid" }, { "name": "index", "in": "path", "required": true, "schema": { "type": "integer", "minimum": 0 } }],
      "get": { "summary": "A part's photo (oldest first)", "responses": { "200": { "description": "The image", "content": { "image/jpeg": {}, "image/png": {} } }, "404": { "$ref": "#/components/responses/Error" } } }
    },
    "/api/locations": {
      "get": { "summary": "Storage locations", "responses": { "200": { "description": "Locations", "content": { "application/json": { "schema": { "type": "object", "properties": {
        "locations": { "type": "array", "items": { "$ref": "#/components/schemas/Location" } } } } } } } } },
      "post": { "summary": "Make a location from a path (missing levels too)",
                "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object", "properties": { "path": { "type": "string" } }, "required": ["path"] } } } },
                "responses": { "201": { "description": "The location", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Location" } } } } } }
    },
    "/api/projects": { "get": { "summary": "Projects (BOMs) with how many boards stock can build", "responses": { "200": { "description": "Projects" } } } },
    "/api/projects/{uid}": {
      "parameters": [{ "$ref": "#/components/parameters/uid" }],
      "get": { "summary": "A project's lines with need, have and the matched part", "responses": { "200": { "description": "The project" }, "404": { "$ref": "#/components/responses/Error" } } }
    },
    "/api/lookup": {
      "get": {
        "summary": "Look a part number up at Digi-Key and Mouser (needs the keys set in the app)",
        "parameters": [{ "name": "q", "in": "query", "required": true, "schema": { "type": "string" } }],
        "responses": { "200": { "description": "Listings", "content": { "application/json": { "schema": { "type": "object", "properties": {
          "results": { "type": "array", "items": { "$ref": "#/components/schemas/SupplierProduct" } }, "count": { "type": "integer" },
          "errors": { "type": "object", "additionalProperties": { "type": "string" } } } } } } }, "409": { "$ref": "#/components/responses/Error" } }
      }
    },
    "/api/identify": {
      "post": {
        "summary": "Identify a part from a photo: markings, bag-label barcodes and look",
        "requestBody": { "required": true, "content": {
          "image/jpeg": {}, "image/png": {}, "image/heic": {},
          "multipart/form-data": { "schema": { "type": "object", "properties": { "image": { "type": "string", "format": "binary" } } } },
          "application/json": { "schema": { "type": "object", "properties": { "image": { "type": "string", "description": "base64" } }, "required": ["image"] } } } },
        "responses": { "200": { "description": "Markings, bag label and ranked candidates" }, "400": { "$ref": "#/components/responses/Error" } }
      }
    },
    "/api/export": {
      "get": { "summary": "The whole inventory as a backup file (the web version's format)",
               "parameters": [{ "name": "photos", "in": "query", "schema": { "type": "boolean", "default": false } }],
               "responses": { "200": { "description": "gw-parts-inventory backup, version 1" } } }
    },
    "/api/import": {
      "post": { "summary": "Merge a backup file: new items added, newer versions win, nothing deleted",
                "requestBody": { "required": true, "content": { "application/json": {} } },
                "responses": { "200": { "description": "Counts" }, "400": { "$ref": "#/components/responses/Error" } } }
    },
    "/mcp": {
      "post": { "summary": "Model Context Protocol (Streamable HTTP, JSON responses): initialize, tools/list, tools/call, ping", "responses": { "200": { "description": "JSON-RPC response" }, "202": { "description": "Notification accepted" } } }
    }
  }
}
"""#
}
