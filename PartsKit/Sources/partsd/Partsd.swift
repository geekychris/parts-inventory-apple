import Foundation
import PartsKit
import PartsServer

// partsd: the inventory's REST API and MCP server without the app — for Linux (and anywhere else PartsKit builds).
//
//   partsd [--data DIR] [--port N] [--all-interfaces] [--print-token]
//
// DIR (default $PARTSD_DATA, else ~/.local/share/partsd) holds inventory.json (the web tool's backup format),
// photos/ and token, the bearer token, made on first run. Supplier lookups use DIGIKEY_CLIENT_ID,
// DIGIKEY_CLIENT_SECRET and MOUSER_API_KEY from the environment. Move an inventory in from the app with
// its JSON backup: `curl -H "Authorization: Bearer $(cat DIR/token)" --data-binary @backup.json http://HOST:8765/api/import`.

@main
enum Partsd {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        var args = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            defer { args.removeSubrange(i...(i + 1)) }
            return args[i + 1]
        }
        func flag(_ name: String) -> Bool {
            guard let i = args.firstIndex(of: name) else { return false }
            args.remove(at: i)
            return true
        }

        if flag("--help") || flag("-h") {
            print("usage: partsd [--data DIR] [--port N] [--all-interfaces] [--print-token]")
            exit(0)
        }
        let home = env["HOME"] ?? FileManager.default.currentDirectoryPath
        let dataDir = URL(fileURLWithPath: option("--data") ?? env["PARTSD_DATA"] ?? "\(home)/.local/share/partsd", isDirectory: true)
        let port = option("--port").map { Int($0) ?? -1 } ?? env["PARTSD_PORT"].flatMap(Int.init) ?? 8765
        let allInterfaces = flag("--all-interfaces") || env["PARTSD_ALL_INTERFACES"] == "1"
        let printToken = flag("--print-token")
        guard (1...65535).contains(port) else { die("--port takes a number from 1 to 65535.") }
        guard args.isEmpty else { die("didn't understand \(args.joined(separator: " ")); see --help.") }

        // The token: made once and kept, owner-only, so tools set up with it keep working.
        do { try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true) } catch { die("can't make \(dataDir.path): \(error.localizedDescription)") }
        let tokenFile = dataDir.appendingPathComponent("token")
        var token = (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if token.isEmpty {
            token = RequestGuard.makeToken()
            guard FileManager.default.createFile(atPath: tokenFile.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
                die("can't write \(tokenFile.path)")
            }
        }
        if printToken { print(token); exit(0) }

        let lookup = SupplierLookup(digikeyID: env["DIGIKEY_CLIENT_ID"] ?? "", digikeySecret: env["DIGIKEY_CLIENT_SECRET"] ?? "", mouserKey: env["MOUSER_API_KEY"] ?? "")
        let server: PartsServer
        do { server = try PartsServer(dataDirectory: dataDir, lookup: lookup) } catch { die("can't read the inventory in \(dataDir.path): \(error.localizedDescription)") }

        let hostName = ProcessInfo.processInfo.hostName.lowercased()
        let hostNames: Set<String> = hostName.isEmpty ? [] : [hostName, hostName.replacingOccurrences(of: ".local", with: ""), hostName.hasSuffix(".local") ? hostName : hostName + ".local"]
        let fixedToken = token
        let gate = await server.gate(token: { fixedToken }, extraOriginHosts: allInterfaces ? hostNames : [])
        let http = HTTPServer { req in await gate.handle(req) }
        http.onState = { state in
            switch state {
            case .listening(let p): log("partsd: listening on \(allInterfaces ? "every interface" : "127.0.0.1"), port \(p)")
            case .failed(let e): die("couldn't start: \(e)")
            case .stopped, .starting: break
            }
        }

        let parts = await server.partCount
        log("partsd \(PartsServer.version): \(parts) part\(parts == 1 ? "" : "s") in \(dataDir.path)")
        log("partsd: supplier lookups — Digi-Key: \(lookup.digikey == nil ? "no keys" : "keys set"), Mouser: \(lookup.mouser == nil ? "no key" : "key set")")
        log("partsd: token in \(tokenFile.path)")
        let base = "http://\(allInterfaces && !hostName.isEmpty ? hostName : "127.0.0.1"):\(port)"
        log("partsd: claude mcp add --transport http parts-inventory \(base)/mcp --header \"Authorization: Bearer $(cat \(tokenFile.path))\"")
        do { try http.start(port: UInt16(port), allInterfaces: allInterfaces) } catch { die("couldn't start: \(error.localizedDescription)") }

        // Serve until stopped. Every change is already on disk, so SIGTERM and SIGINT can simply end the process.
        while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

    /// A line to stdout, unbuffered, so it reaches the journal as it happens.
    static func log(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

    static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data("partsd: \(message)\n".utf8))
        exit(1)
    }
}
