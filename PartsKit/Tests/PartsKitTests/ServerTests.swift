import Foundation
import Testing
@testable import PartsKit

// MARK: - HTTP parsing

@Test func parsesAGetWithQuery() throws {
    let raw = "GET /api/parts?q=10k%200603&low=true HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\n\r\n"
    guard case .complete(let r) = HTTPParser.parse(Data(raw.utf8)) else { Issue.record("not complete"); return }
    #expect(r.method == "GET")
    #expect(r.path == "/api/parts")
    #expect(r.query["q"] == "10k 0603")
    #expect(r.query["low"] == "true")
    #expect(r.header("AUTHORIZATION") == "Bearer abc")
    #expect(r.body.isEmpty)
}

@Test func waitsForTheWholeBody() {
    let head = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
    guard case .incomplete = HTTPParser.parse(Data((head + "12345").utf8)) else { Issue.record("should wait"); return }
    guard case .complete(let r) = HTTPParser.parse(Data((head + "1234567890extra").utf8)) else { Issue.record("not complete"); return }
    #expect(String(decoding: r.body, as: UTF8.self) == "1234567890")
}

@Test func waitsForTheHeaders() {
    guard case .incomplete = HTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) else { Issue.record("should wait"); return }
}

@Test func decodesAChunkedBody() {
    let raw = "POST /api/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n"
    guard case .complete(let r) = HTTPParser.parse(Data(raw.utf8)) else { Issue.record("not complete"); return }
    #expect(String(decoding: r.body, as: UTF8.self) == "hello world")
    guard case .incomplete = HTTPParser.parse(Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel".utf8)) else { Issue.record("should wait"); return }
}

@Test func refusesMalformedRequests() {
    func status(_ s: String, maxBody: Int = 1024) -> Int? {
        if case .failed(let r) = HTTPParser.parse(Data(s.utf8), maxBody: maxBody) { return r.status }
        return nil
    }
    #expect(status("NONSENSE\r\n\r\n") == 400)
    #expect(status("GET / HTTP/1.1\r\nNoColonHere\r\n\r\n") == 400)
    #expect(status("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n") == 400)
    #expect(status("POST / HTTP/1.1\r\nContent-Length: 5000\r\n\r\n", maxBody: 1000) == 413)
    #expect(status("GET / HTTP/1.1\r\n" + String(repeating: "X-A: b\r\n", count: 10_000) + "\r\n") == 431)
}

@Test func writesAResponse() {
    let r = HTTPResponse.json(.object(["ok": .bool(true)]), status: 201)
    let text = String(decoding: r.serialized(), as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 201 Created\r\n"))
    #expect(text.contains("Content-Type: application/json"))
    #expect(text.contains("Content-Length: 11\r\n"))
    #expect(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
}

// MARK: - Routes and checks

@Test func routesMatchWithNamedSegments() {
    let p = RoutePattern("/api/parts/{uid}/stock")
    #expect(p.match("/api/parts/p123/stock") == ["uid": "p123"])
    #expect(p.match("/api/parts/p123") == nil)
    #expect(p.match("/api/parts/p123/photos") == nil)
    #expect(RoutePattern("/api/parts").match("/api/parts/") == [:])
    #expect(RoutePattern("/api/parts/{uid}/photos/{index}").match("/api/parts/a/photos/2") == ["uid": "a", "index": "2"])
}

@Test func needsTheRightToken() {
    var r = HTTPRequest(method: "GET", path: "/api/parts")
    #expect(!RequestGuard.authorised(r, token: "secret"))
    r.headers["authorization"] = "Bearer wrong!"
    #expect(!RequestGuard.authorised(r, token: "secret"))
    r.headers["authorization"] = "Bearer secret"
    #expect(RequestGuard.authorised(r, token: "secret"))
    r.headers["authorization"] = "bearer secret"
    #expect(RequestGuard.authorised(r, token: "secret"))
    #expect(!RequestGuard.authorised(r, token: ""))
}

@Test func onlyLocalOriginsGetIn() {
    var r = HTTPRequest(method: "POST", path: "/mcp")
    #expect(RequestGuard.originAllowed(r))
    for ok in ["http://localhost:3000", "http://127.0.0.1:8765", "https://[::1]:9"] {
        r.headers["origin"] = ok
        #expect(RequestGuard.originAllowed(r), "\(ok)")
    }
    for bad in ["https://evil.example", "null", "http://192.168.1.5"] {
        r.headers["origin"] = bad
        #expect(!RequestGuard.originAllowed(r), "\(bad)")
    }
    r.headers["origin"] = "http://192.168.1.5"
    #expect(RequestGuard.originAllowed(r, extraHosts: ["192.168.1.5"]))
}

@Test func tokensAreLongAndDifferent() {
    let a = RequestGuard.makeToken(), b = RequestGuard.makeToken()
    #expect(a.count >= 43 && a != b)
    #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
}

// MARK: - MCP

struct FakeTools: MCPToolProvider {
    func tools() async -> [MCPTool] {
        [MCPTool(name: "echo", title: "Echo", description: "Says it back", inputSchema: JSONSchema.object(["text": JSONSchema.string("What to say")], required: ["text"]), readOnly: true)]
    }
    func call(_ name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        guard let t = arguments["text"]?.string else { return .failure("text is required") }
        return MCPToolResult(summary: "Echoed.", data: .object(["text": .string(t)]))
    }
}

func mcpPost(_ e: MCPEndpoint, _ body: String, headers: [String: String] = [:]) async -> HTTPResponse {
    await e.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers.merging(["content-type": "application/json"]) { a, _ in a }, body: Data(body.utf8)))
}

@Test func mcpRoundTrip() async throws {
    let e = MCPEndpoint(name: "parts-inventory", version: "1.0", instructions: "Test", provider: FakeTools())
    let initRes = await mcpPost(e, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
    #expect(initRes.status == 200)
    let sid = try #require(initRes.header("Mcp-Session-Id"))
    let initJSON = try #require(try? JSONDecoder().decode(JSONValue.self, from: initRes.body))
    #expect(initJSON["result"]?["protocolVersion"]?.string == "2025-06-18")
    #expect(initJSON["result"]?["capabilities"]?["tools"] != nil)
    #expect(initJSON["result"]?["serverInfo"]?["name"]?.string == "parts-inventory")

    let h = ["mcp-session-id": sid, "mcp-protocol-version": "2025-06-18"]
    let note = await mcpPost(e, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, headers: h)
    #expect(note.status == 202 && note.body.isEmpty)

    let list = await mcpPost(e, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, headers: h)
    let listJSON = try #require(try? JSONDecoder().decode(JSONValue.self, from: list.body))
    #expect(listJSON["result"]?["tools"]?.array?.first?["name"]?.string == "echo")
    #expect(listJSON["result"]?["tools"]?.array?.first?["inputSchema"]?["required"] == .array([.string("text")]))

    let call = await mcpPost(e, #"{"jsonrpc":"2.0","id":"c3","method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#, headers: h)
    let callJSON = try #require(try? JSONDecoder().decode(JSONValue.self, from: call.body))
    #expect(callJSON["id"]?.string == "c3")
    #expect(callJSON["result"]?["isError"] == .bool(false))
    #expect(callJSON["result"]?["content"]?.array?.first?["text"]?.string?.contains("\"text\":\"hi\"") == true)

    let bad = await mcpPost(e, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#, headers: h)
    let badJSON = try #require(try? JSONDecoder().decode(JSONValue.self, from: bad.body))
    #expect(badJSON["result"]?["isError"] == .bool(true))

    let unknown = await mcpPost(e, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#, headers: h)
    #expect((try? JSONDecoder().decode(JSONValue.self, from: unknown.body))?["error"]?["code"]?.int == -32602)

    let missing = await mcpPost(e, #"{"jsonrpc":"2.0","id":6,"method":"resources/read"}"#, headers: h)
    #expect((try? JSONDecoder().decode(JSONValue.self, from: missing.body))?["error"]?["code"]?.int == -32601)

    let ping = await mcpPost(e, #"[{"jsonrpc":"2.0","id":7,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/cancelled"}]"#, headers: h)
    #expect((try? JSONDecoder().decode(JSONValue.self, from: ping.body))?.array?.count == 1)

    let ended = await e.handle(HTTPRequest(method: "DELETE", path: "/mcp", headers: ["mcp-session-id": sid]))
    #expect(ended.status == 204)
    let afterEnd = await mcpPost(e, #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#, headers: h)
    #expect(afterEnd.status == 404)
}

@Test func mcpNegotiatesAndRefuses() async throws {
    let e = MCPEndpoint(name: "p", version: "1", instructions: "", provider: FakeTools())
    let r = await mcpPost(e, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
    #expect((try? JSONDecoder().decode(JSONValue.self, from: r.body))?["result"]?["protocolVersion"]?.string == MCPEndpoint.supportedVersions[0])
    #expect((await mcpPost(e, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, headers: ["mcp-protocol-version": "1999-01-01"])).status == 400)
    #expect((await mcpPost(e, "not json")).status == 400)
    #expect((await e.handle(HTTPRequest(method: "GET", path: "/mcp"))).status == 405)
}

// MARK: - The server, end to end

@Test func serverAnswersOverTheNetwork() async throws {
    let server = HTTPServer { req in
        if req.path == "/echo" { return .json(.object(["method": .string(req.method), "body": .string(String(decoding: req.body, as: UTF8.self)), "q": .string(req.query["q"] ?? "")])) }
        return .error(404, "nope")
    }
    try server.start(port: 0)
    defer { server.stop() }
    guard case .listening(let port) = await server.waitUntilReady() else { Issue.record("not listening: \(server.state)"); return }
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/echo?q=a%20b")!)
    req.httpMethod = "POST"
    req.httpBody = Data(String(repeating: "x", count: 300_000).utf8)   // more than one read
    let (data, res) = try await URLSession.shared.data(for: req)
    #expect((res as? HTTPURLResponse)?.statusCode == 200)
    let j = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(j["method"]?.string == "POST")
    #expect(j["q"]?.string == "a b")
    #expect(j["body"]?.string?.count == 300_000)
    let (_, res404) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/other")!)
    #expect((res404 as? HTTPURLResponse)?.statusCode == 404)
}

// MARK: - The front door

@Test func gateChecksOriginTokenAndRoutes() async throws {
    let mcp = MCPEndpoint(name: "p", version: "1", instructions: "", provider: FakeTools())
    let gate = APIGate(token: { "tok" }, mcp: mcp) { req in .json(.object(["path": .string(req.path)])) }
    func status(_ method: String, _ path: String, _ headers: [String: String] = [:], body: String = "") async -> Int {
        await gate.handle(HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))).status
    }
    #expect(await status("GET", "/api/health") == 200)
    #expect(await status("GET", "/api/parts") == 401)
    #expect(await status("POST", "/mcp") == 401)
    #expect(await status("GET", "/api/parts", ["authorization": "Bearer tok"]) == 200)
    #expect(await status("GET", "/api/parts", ["authorization": "Bearer tok", "origin": "https://evil.example"]) == 403)
    #expect(await status("GET", "/elsewhere", ["authorization": "Bearer tok"]) == 404)
    #expect(await status("POST", "/mcp", ["authorization": "Bearer tok"], body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) == 200)
    let r = await gate.handle(HTTPRequest(method: "GET", path: "/api/parts/", headers: ["authorization": "Bearer tok"]))
    #expect(try JSONDecoder().decode(JSONValue.self, from: r.body)["path"]?.string == "/api/parts")
    let unauth = await gate.handle(HTTPRequest(method: "GET", path: "/api/parts"))
    #expect(unauth.header("WWW-Authenticate")?.hasPrefix("Bearer") == true)
}

@Test func readsTheFileFromAMultipartBody() {
    let body = "--XyZ\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nhello\r\n--XyZ\r\nContent-Disposition: form-data; name=\"image\"; filename=\"a.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nJPEGDATA\r\n--XyZ--\r\n"
    let f = Multipart.firstFile(Data(body.utf8), contentType: "multipart/form-data; boundary=XyZ")
    #expect(f.map { String(decoding: $0.data, as: UTF8.self) } == "JPEGDATA")
    #expect(f?.type == "image/jpeg")
}
