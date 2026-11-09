import Foundation
import PartsKit

/// partsd's web pages (Sources/PartsServer/Web: one page and its script and styles), served from a directory
/// outside /api and /mcp. They hold no data — everything comes from the API with the token the page is given — so
/// they're served without it. Only GET and HEAD, only files directly in the directory.
public struct WebSite: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The first of `candidates` holding an index.html.
    public static func find(_ candidates: [URL]) -> WebSite? {
        candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }.map(WebSite.init)
    }

    static let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
                        "svg": "image/svg+xml", "png": "image/png", "ico": "image/x-icon", "json": "application/json; charset=utf-8",
                        "webmanifest": "application/manifest+json"]

    public func handle(_ req: HTTPRequest) -> HTTPResponse {
        guard req.method == "GET" || req.method == "HEAD" else {
            return HTTPResponse(status: 405, headers: [("Allow", "GET, HEAD")], body: JSONValue.encode(.object(["error": .string("Use GET here.")])))
        }
        let name = req.path == "/" ? "index.html" : String(req.path.dropFirst())
        // One file name: no directories, no dot files (and so no "..").
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."),
              let type = Self.types[(name as NSString).pathExtension.lowercased()],
              let d = FileManager.default.contents(atPath: root.appendingPathComponent(name).path) else {
            return .error(404, "Nothing here. The web pages are at /, the REST API is under /api (see /api/openapi.json) and the MCP endpoint is /mcp.")
        }
        var headers = [("Content-Type", type), ("Cache-Control", "no-cache"), ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer")]
        // The page loads nothing from elsewhere; images it shows are its own (blob:) or the suppliers' pictures.
        if type.hasPrefix("text/html") {
            headers.append(("Content-Security-Policy", "default-src 'self'; img-src 'self' blob: data: https:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"))
            headers.append(("X-Frame-Options", "DENY"))
        }
        return HTTPResponse(status: 200, headers: headers, body: req.method == "HEAD" ? Data() : d)
    }
}
