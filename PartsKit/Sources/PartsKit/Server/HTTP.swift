import Foundation

// A small HTTP/1.1 server's pieces: parsing a request from bytes, writing a response, matching routes, and the
// checks every request goes through (the bearer token and the Origin header). Nothing here knows about parts.

public struct HTTPRequest: Sendable {
    public var method: String
    /// The path without the query, percent-decoded ("/api/parts/p123").
    public var path: String
    public var query: [String: String]
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The body as JSON (nil when it's empty or not JSON).
    public var json: JSONValue? { body.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: body) }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

    public static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: JSONValue.encode(value))
    }

    public static func json<T: Encodable>(encoding value: T, status: Int = 200) -> HTTPResponse {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? e.encode(value)) ?? Data("null".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: body)
    }

    /// `{"error": "…"}` with the status.
    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(.object(["error": .string(message)]), status: status)
    }

    public static func empty(_ status: Int) -> HTTPResponse { HTTPResponse(status: status) }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"; case 201: "Created"; case 202: "Accepted"; case 204: "No Content"
        case 400: "Bad Request"; case 401: "Unauthorized"; case 403: "Forbidden"; case 404: "Not Found"
        case 405: "Method Not Allowed"; case 409: "Conflict"; case 411: "Length Required"; case 413: "Content Too Large"
        case 415: "Unsupported Media Type"; case 422: "Unprocessable Content"; case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"; case 501: "Not Implemented"; case 502: "Bad Gateway"; case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }

    /// The bytes on the wire. Adds Content-Length and Connection: close (one request per connection).
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers where k.lowercased() != "content-length" && k.lowercased() != "connection" { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var d = Data(head.utf8)
        d.append(body)
        return d
    }
}

public enum HTTPParser {
    public enum Result: Sendable {
        /// More bytes are needed.
        case incomplete
        case complete(HTTPRequest)
        /// The request can't be served; answer with this and close.
        case failed(HTTPResponse)
    }

    public static let maxHeaderBytes = 64 * 1024

    /// Parse one request from the bytes received so far.
    public static func parse(_ data: Data, maxBody: Int = 20 * 1024 * 1024) -> Result {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .failed(.error(431, "The request's headers are too large.")) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .failed(.error(431, "The request's headers are too large.")) }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .failed(.error(400, "The request's headers aren't text."))
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard start.count == 3, start[2].hasPrefix("HTTP/1."), let target = start.first.map({ _ in String(start[1]) }) else {
            return .failed(.error(400, "That isn't an HTTP/1.1 request."))
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .failed(.error(400, "A header line has no colon.")) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .failed(.error(400, "A header has no name.")) }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let bodyStart = end.upperBound
        let rest = data[bodyStart...]
        var body = Data()
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch dechunk(Data(rest), maxBody: maxBody) {
            case .incomplete: return .incomplete
            case .failed(let r): return .failed(r)
            case .complete(let b): body = b
            }
        } else if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .failed(.error(400, "Content-Length isn't a number.")) }
            guard n <= maxBody else { return .failed(.error(413, "The request body is larger than \(maxBody / 1024 / 1024) MB.")) }
            guard rest.count >= n else { return .incomplete }
            body = Data(rest.prefix(n))
        }
        let (path, query) = splitTarget(target)
        return .complete(HTTPRequest(method: String(start[0]).uppercased(), path: path, query: query, headers: headers, body: body))
    }

    private enum Chunks { case incomplete, failed(HTTPResponse), complete(Data) }

    private static func dechunk(_ data: Data, maxBody: Int) -> Chunks {
        var out = Data(), i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data[i...].firstRange(of: crlf) else { return .incomplete }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return .failed(.error(400, "A chunk size isn't hexadecimal.")) }
            let chunkStart = lineEnd.upperBound
            if size == 0 { return .complete(out) }
            guard out.count + size <= maxBody else { return .failed(.error(413, "The request body is larger than \(maxBody / 1024 / 1024) MB.")) }
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return .incomplete }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            out.append(data[chunkStart..<chunkEnd])
            i = data.index(chunkEnd, offsetBy: 2)
        }
    }

    /// "/api/parts?q=10k%200603" → ("/api/parts", ["q": "10k 0603"]).
    public static func splitTarget(_ target: String) -> (String, [String: String]) {
        var target = target
        // An absolute-form target ("http://host/path") — keep the path.
        if let r = target.range(of: "://"), let slash = target[r.upperBound...].firstIndex(of: "/") { target = String(target[slash...]) }
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                func decode(_ s: Substring) -> String { String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s) }
                query[decode(kv[0])] = kv.count > 1 ? decode(kv[1]) : ""
            }
        }
        return (path, query)
    }
}

/// A route like "/api/parts/{uid}/stock": matches a path and pulls out the named segments.
public struct RoutePattern: Sendable, Hashable {
    public let pattern: String
    private let segments: [String]

    public init(_ pattern: String) {
        self.pattern = pattern
        segments = pattern.split(separator: "/").map(String.init)
    }

    public func match(_ path: String) -> [String: String]? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == segments.count else { return nil }
        var out: [String: String] = [:]
        for (s, p) in zip(segments, parts) {
            if s.hasPrefix("{") && s.hasSuffix("}") { out[String(s.dropFirst().dropLast())] = p }
            else if s != p { return nil }
        }
        return out
    }
}

/// The checks before any handler runs.
public enum RequestGuard {
    /// Whether `Authorization: Bearer <token>` matches, compared in constant time.
    public static func authorised(_ req: HTTPRequest, token: String) -> Bool {
        guard !token.isEmpty, let auth = req.header("authorization") else { return false }
        let parts = auth.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let a = Array(parts[1].trimmingCharacters(in: .whitespaces).utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// No Origin (tools, curl, Claude Code), or a page served from this machine. Anything else — a web page
    /// elsewhere trying to reach the server through the browser (DNS rebinding) — is refused.
    public static func originAllowed(_ req: HTTPRequest, extraHosts: Set<String> = []) -> Bool {
        guard let origin = req.header("origin"), !origin.isEmpty else { return true }
        if origin == "null" { return false }
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || extraHosts.contains(host)
    }

    /// A random token for the API: 32 bytes, base64url.
    public static func makeToken() -> String {
        var g = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - JSON helpers

extension JSONValue {
    public static func encode(_ v: JSONValue) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)) ?? Data("null".utf8)
    }

    /// Any Encodable as a JSONValue.
    public static func from<T: Encodable>(_ v: T) -> JSONValue {
        guard let d = try? JSONEncoder().encode(v), let j = try? JSONDecoder().decode(JSONValue.self, from: d) else { return .null }
        return j
    }

    /// Decode this value as a Decodable type.
    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var int: Int? {
        if case .number(let n) = self, n.rounded() == n, abs(n) < 1e15 { return Int(n) }
        if case .string(let s) = self { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    public var isNull: Bool { self == .null }

    /// Compact JSON text.
    public var text: String { String(decoding: Self.encode(self), as: UTF8.self) }
}
