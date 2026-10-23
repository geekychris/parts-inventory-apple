import Foundation

/// The front door: the Origin check, the bearer token, then /mcp to the MCP endpoint and /api/… to the REST
/// handler. /api/health answers without a token so tools can see the server is up.
public struct APIGate: Sendable {
    public var token: @Sendable () -> String
    public var mcp: MCPEndpoint
    public var rest: HTTPServer.Handler
    /// Hosts allowed in an Origin header besides this machine's (when serving the local network).
    public var extraOriginHosts: Set<String>

    public init(token: @escaping @Sendable () -> String, mcp: MCPEndpoint, extraOriginHosts: Set<String> = [], rest: @escaping HTTPServer.Handler) {
        self.token = token; self.mcp = mcp; self.rest = rest; self.extraOriginHosts = extraOriginHosts
    }

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        guard RequestGuard.originAllowed(req, extraHosts: extraOriginHosts) else {
            return .error(403, "Requests from web pages on other sites aren't allowed.")
        }
        let path = req.path.count > 1 && req.path.hasSuffix("/") ? String(req.path.dropLast()) : req.path
        if path == "/api/health" { return await rest(req) }
        guard path == "/mcp" || path == "/api" || path.hasPrefix("/api/") else {
            return .error(404, "Nothing here. The REST API is under /api (see /api/openapi.json) and the MCP endpoint is /mcp.")
        }
        guard RequestGuard.authorised(req, token: token()) else {
            var r = HTTPResponse.error(401, "Send the API token from e-Parts Inventory Manager › Settings › API & MCP as “Authorization: Bearer <token>”.")
            r.headers.append(("WWW-Authenticate", "Bearer realm=\"e-Parts Inventory Manager\""))
            return r
        }
        if path == "/mcp" { return await mcp.handle(req) }
        var r = req
        r.path = path
        return await rest(r)
    }
}

/// The first file in a multipart/form-data body.
public enum Multipart {
    public static func firstFile(_ body: Data, contentType: String) -> (data: Data, type: String)? {
        guard let b = contentType.components(separatedBy: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.lowercased().hasPrefix("boundary=") })?.dropFirst("boundary=".count) else { return nil }
        let boundary = Data(("--" + String(b).trimmingCharacters(in: CharacterSet(charactersIn: "\""))).utf8)
        let headEnd = Data("\r\n\r\n".utf8)
        var i = body.startIndex
        while let start = body[i...].firstRange(of: boundary) {
            let partStart = start.upperBound
            guard let next = body[partStart...].firstRange(of: boundary) else { return nil }
            let part = body[partStart..<next.lowerBound]
            if let h = part.firstRange(of: headEnd) {
                let head = String(decoding: part[part.startIndex..<h.lowerBound], as: UTF8.self).lowercased()
                var content = part[h.upperBound...]
                if content.suffix(2) == Data("\r\n".utf8) { content = content.dropLast(2) }
                let type = head.components(separatedBy: "\r\n").first { $0.hasPrefix("content-type:") }?
                    .dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces) ?? ""
                if head.contains("filename=") || type.hasPrefix("image/") { return (Data(content), type) }
            }
            i = next.lowerBound
        }
        return nil
    }
}
