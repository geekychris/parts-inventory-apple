import Foundation

/// A friend's published inventory: a folder (usually a GitHub repository) with `inventory.json` at its root —
/// a backup file. Only that file is read.
public enum RemoteInventory {
    public static let fileName = "inventory.json"

    public enum Failure: LocalizedError, Equatable {
        case badAddress(String), unsupportedScheme(String), notFound(String), notInventory(String), http(Int, String), network(String)
        public var errorDescription: String? {
            switch self {
            case .badAddress(let a): "“\(a)” isn’t a web address."
            case .unsupportedScheme(let s): "Only http and https addresses work (not \(s):). For a folder on this device, choose the folder instead."
            case .notFound(let u): "There’s no inventory at \(u). Check the address — and that the repository is public."
            case .notInventory(let m): "That isn’t an inventory file. \(m)"
            case .http(let code, let u): "The server answered \(code) (\(HTTPURLResponse.localizedString(forStatusCode: code))) for \(u)."
            case .network(let m): "Couldn’t reach it: \(m)"
            }
        }
    }

    /// Where to fetch `inventory.json` from, given what someone typed:
    /// - `https://github.com/owner/repo` → `https://raw.githubusercontent.com/owner/repo/HEAD/inventory.json`
    /// - `…/tree/<ref>/<path>` → raw `<ref>/<path>/inventory.json`; `…/blob/<ref>/<path>.json` → raw
    /// - a raw URL, or any address ending in .json, as it is; any other http(s) address + `/inventory.json`.
    /// "github.com/owner/repo" without a scheme is taken as https.
    public static func resolve(_ typed: String) throws -> URL {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw Failure.badAddress(typed) }
        if !s.contains("://") {
            if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("."), !s[..<colon].contains("/") {
                throw Failure.unsupportedScheme(String(s[..<colon]))   // mailto:, file: without slashes…
            }
            s = "https://" + s
        }
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased() else { throw Failure.badAddress(typed) }
        guard scheme == "http" || scheme == "https" else { throw Failure.unsupportedScheme(scheme) }
        guard let host = c.host?.lowercased(), !host.isEmpty else { throw Failure.badAddress(typed) }
        let parts = c.path.split(separator: "/").map(String.init)

        if host == "github.com" || host == "www.github.com" {
            guard parts.count >= 2 else { throw Failure.badAddress(typed) }
            let owner = parts[0], repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
            var raw = [owner, repo]
            switch parts.count {
            case 2: raw += ["HEAD", fileName]
            case 4... where parts[2] == "tree":
                raw += Array(parts[3...]) + [fileName]
            case 5... where parts[2] == "blob" || parts[2] == "raw":
                raw += Array(parts[3...])
                if !raw.last!.lowercased().hasSuffix(".json") { raw.append(fileName) }
            default: throw Failure.badAddress(typed)
            }
            var r = URLComponents()
            r.scheme = "https"; r.host = "raw.githubusercontent.com"; r.path = "/" + raw.joined(separator: "/")
            return r.url!
        }
        if !c.path.lowercased().hasSuffix(".json") {
            c.path = (c.path.hasSuffix("/") ? c.path : c.path + "/") + fileName
        }
        guard let url = c.url else { throw Failure.badAddress(typed) }
        return url
    }

    /// Read an inventory file.
    public static func decode(_ data: Data) throws -> Backup {
        do { return try Backup.read(data).backup }
        catch let e as Backup.ReadError {
            switch e {
            case .notJSON: throw Failure.notInventory(looksLikeHTML(data) ? "The address gave a web page, not inventory.json." : "It isn’t JSON.")
            default: throw Failure.notInventory(e.localizedDescription)
            }
        }
    }

    /// Fetch and read an inventory from the web.
    public static func fetch(_ url: URL, session: URLSession = .shared, timeout: TimeInterval = 20) async throws -> Backup {
        try decode(await fetchData(url, session: session, timeout: timeout))
    }

    /// Fetch the file's bytes (for keeping a copy), with the failures in plain words.
    public static func fetchData(_ url: URL, session: URLSession = .shared, timeout: TimeInterval = 20) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError {
            let why = switch e.code {
            case .notConnectedToInternet: "there’s no internet connection."
            case .timedOut: "it took too long to answer."
            case .cannotFindHost, .dnsLookupFailed: "the server \(url.host ?? "") wasn’t found."
            case .cannotConnectToHost: "the server \(url.host ?? "") refused the connection."
            default: e.localizedDescription
            }
            throw Failure.network(why)
        }
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw h.statusCode == 404 || h.statusCode == 410 ? Failure.notFound(url.absoluteString) : Failure.http(h.statusCode, url.absoluteString)
        }
        return data
    }

    /// Read `inventory.json` in a folder on this device.
    public static func read(folder: URL) throws -> Backup { try decode(readData(folder: folder)) }

    public static func readData(folder: URL) throws -> Data {
        let file = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.notFound(file.path) }
        return try Data(contentsOf: file)
    }
    static func looksLikeHTML(_ d: Data) -> Bool {
        let head = String(decoding: d.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }
}
