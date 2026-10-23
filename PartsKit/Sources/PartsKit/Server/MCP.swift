import Foundation

// The Model Context Protocol over Streamable HTTP (one endpoint, POST in, JSON out — no server-sent events):
// initialize, tools/list, tools/call and ping. The tools themselves come from whoever owns the data.

/// A tool, as tools/list describes it.
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    /// A JSON Schema object for the arguments.
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool = false, destructive: Bool = false) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema
        self.readOnly = readOnly; self.destructive = destructive
    }

    var listing: JSONValue {
        .object([
            "name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": inputSchema,
            "annotations": .object(["title": .string(title), "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive),
                                    "idempotentHint": .bool(readOnly), "openWorldHint": .bool(false)]),
        ])
    }
}

/// What a tool call returns: a short summary for people and the data as JSON.
public struct MCPToolResult: Sendable {
    public var summary: String
    public var data: JSONValue?
    public var isError: Bool

    public init(summary: String, data: JSONValue? = nil, isError: Bool = false) { self.summary = summary; self.data = data; self.isError = isError }
    public static func failure(_ message: String) -> MCPToolResult { MCPToolResult(summary: message, isError: true) }

    var json: JSONValue {
        var text = summary
        if let data { text += "\n\n" + data.text }
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)])
    }
}

/// Supplies the tools and runs them.
public protocol MCPToolProvider: Sendable {
    func tools() async -> [MCPTool]
    func call(_ name: String, arguments: [String: JSONValue]) async -> MCPToolResult
}

/// A tool name the provider doesn't know.
public struct MCPUnknownTool: Error {}

/// One MCP endpoint: sessions, version negotiation and the JSON-RPC methods.
public final class MCPEndpoint: @unchecked Sendable {
    /// Newest first. 2025-03-26 is what a client that sends no version header is assumed to speak.
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    public let name: String
    public let version: String
    public let instructions: String
    private let provider: MCPToolProvider
    private let lock = NSLock()
    private var sessions: [String: String] = [:]   // session id → negotiated version

    public init(name: String, version: String, instructions: String, provider: MCPToolProvider) {
        self.name = name; self.version = version; self.instructions = instructions; self.provider = provider
    }

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        switch req.method {
        case "POST": break
        case "DELETE":
            guard let sid = req.header("mcp-session-id") else { return .error(400, "No Mcp-Session-Id to end.") }
            let known = lock.withLock { sessions.removeValue(forKey: sid) != nil }
            return known ? .empty(204) : .error(404, "No such session.")
        case "GET":
            // No server-sent events: everything comes back in the POST's response.
            return HTTPResponse(status: 405, headers: [("Allow", "POST, DELETE")])
        default:
            return HTTPResponse(status: 405, headers: [("Allow", "POST, DELETE")])
        }
        if let v = req.header("mcp-protocol-version"), !Self.supportedVersions.contains(v) {
            return rpcError(nil, -32600, "Unsupported MCP-Protocol-Version \(v); this server speaks \(Self.supportedVersions.joined(separator: ", ")).", status: 400)
        }
        let session = req.header("mcp-session-id")
        if let s = session, !(lock.withLock { sessions[s] != nil }) {
            return rpcError(nil, -32600, "Unknown or ended session; initialize again.", status: 404)
        }
        guard let message = req.json else { return rpcError(nil, -32700, "The body isn't JSON.", status: 400) }

        if case .array(let batch) = message {
            guard !batch.isEmpty else { return rpcError(nil, -32600, "An empty batch.", status: 400) }
            var replies: [JSONValue] = [], newSession: String?
            for m in batch {
                let (reply, sid) = await handleMessage(m)
                if let reply { replies.append(reply) }
                if let sid { newSession = sid }
            }
            if replies.isEmpty { return .empty(202) }
            var r = HTTPResponse.json(.array(replies))
            if let newSession { r.headers.append(("Mcp-Session-Id", newSession)) }
            return r
        }
        let (reply, sid) = await handleMessage(message)
        guard let reply else { return .empty(202) }
        var r = HTTPResponse.json(reply)
        if let sid { r.headers.append(("Mcp-Session-Id", sid)) }
        return r
    }

    /// One JSON-RPC message → its reply (nil for notifications and responses), and a new session id after initialize.
    private func handleMessage(_ m: JSONValue) async -> (JSONValue?, String?) {
        guard case .object(let o) = m, o["jsonrpc"]?.string == "2.0" else {
            return (Self.error(nil, -32600, "Not a JSON-RPC 2.0 message."), nil)
        }
        let id = o["id"]
        guard let method = o["method"]?.string else {
            // A response to something we never asked, or garbage with an id.
            return (o["result"] != nil || o["error"] != nil ? nil : Self.error(id, -32600, "No method."), nil)
        }
        guard let id, !id.isNull else { return (nil, nil) }   // a notification (initialized, cancelled…): accepted
        let params = o["params"]?.object ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            let v = Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0]
            let sid = UUID().uuidString.lowercased()
            lock.withLock { sessions[sid] = v }
            let result: JSONValue = .object([
                "protocolVersion": .string(v),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(name), "title": .string("e-Parts Inventory Manager"), "version": .string(version)]),
                "instructions": .string(instructions),
            ])
            return (Self.result(id, result), sid)
        case "ping":
            return (Self.result(id, .object([:])), nil)
        case "tools/list":
            let tools = await provider.tools()
            return (Self.result(id, .object(["tools": .array(tools.map(\.listing))])), nil)
        case "tools/call":
            guard let name = params["name"]?.string else { return (Self.error(id, -32602, "tools/call needs a tool name."), nil) }
            let tools = await provider.tools()
            guard tools.contains(where: { $0.name == name }) else { return (Self.error(id, -32602, "Unknown tool: \(name)"), nil) }
            let args = params["arguments"]?.object ?? [:]
            let r = await provider.call(name, arguments: args)
            return (Self.result(id, r.json), nil)
        case "resources/list": return (Self.result(id, .object(["resources": .array([])])), nil)
        case "prompts/list": return (Self.result(id, .object(["prompts": .array([])])), nil)
        default:
            return (Self.error(id, -32601, "Method not found: \(method)"), nil)
        }
    }

    static func result(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    static func error(_ id: JSONValue?, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
    private func rpcError(_ id: JSONValue?, _ code: Int, _ message: String, status: Int) -> HTTPResponse {
        .json(Self.error(id, code, message), status: status)
    }
}

// MARK: - Building JSON Schemas for tools

public enum JSONSchema {
    public static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)),
                 "additionalProperties": .bool(false)])
    }
    public static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let values { o["enum"] = .array(values.map(JSONValue.string)) }
        return .object(o)
    }
    public static func integer(_ description: String, minimum: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("integer"), "description": .string(description)]
        if let minimum { o["minimum"] = .number(Double(minimum)) }
        return .object(o)
    }
    public static func boolean(_ description: String) -> JSONValue { .object(["type": .string("boolean"), "description": .string(description)]) }
    public static func strings(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }
}
