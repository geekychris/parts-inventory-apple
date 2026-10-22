import Foundation

/// GET /api/openapi.json.
nonisolated enum OpenAPI {
    static let document = #"""
{
  "openapi": "3.1.0",
  "info": {
    "title": "Parts Inventory",
    "version": "1",
    "description": "The parts inventory in the Parts Inventory app, served by the app itself while it runs (Settings › API & MCP). Parts have the same shape as the web version's backup file, plus locationPath, photoCount, isLow and summary. Every endpoint except /api/health needs Authorization: Bearer <token>. The same data is available as MCP tools at /mcp."
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
