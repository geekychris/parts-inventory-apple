import Foundation
import Observation
import PartsKit
import SwiftData

/// The API and MCP server: on or off, which port, local-only or the whole network, and its token.
/// It serves while the app runs (on iPhone and iPad only while the app is open).
@Observable
final class APIService {
    static let shared = APIService()
    nonisolated static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static let defaultPort = 8765

    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "api.enabled"); restart() } }
    var port: Int { didSet { UserDefaults.standard.set(port, forKey: "api.port") } }
    var allInterfaces: Bool { didSet { UserDefaults.standard.set(allInterfaces, forKey: "api.allInterfaces"); restart() } }
    private(set) var token: String
    private(set) var state: HTTPServer.State = .stopped

    @ObservationIgnored private var server: HTTPServer?
    /// The token as the server's queue reads it.
    @ObservationIgnored private let currentToken = TokenBox()
    @ObservationIgnored private(set) var api: InventoryAPI?

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "api.enabled")
        port = d.object(forKey: "api.port") as? Int ?? Self.defaultPort
        allInterfaces = d.bool(forKey: "api.allInterfaces")
        token = ""
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-apiToken"), i + 1 < args.count { token = args[i + 1] }
        if args.contains("-apiServer") { enabled = true }
        if let i = args.firstIndex(of: "-apiPort"), i + 1 < args.count, let p = Int(args[i + 1]) { port = p }
        #endif
    }

    /// Give the service the app's store and start it when it's switched on.
    func attach(_ container: ModelContainer) {
        api = InventoryAPI(container: container)
        if enabled { start() }
    }

    /// The token, made (and kept in the Keychain) the first time it's needed.
    func ensureToken() -> String {
        if token.isEmpty { token = KeychainStore.get("api.token") }
        if token.isEmpty { regenerateToken() }
        return token
    }

    func regenerateToken() {
        token = RequestGuard.makeToken()
        currentToken.value = token
        KeychainStore.set(token, for: "api.token")
    }

    func start() {
        guard let api else { return }
        server?.stop()
        let tokenNow = ensureToken()
        let mcp = MCPEndpoint(name: "parts-inventory", version: Self.appVersion, instructions: Self.instructions, provider: InventoryTools(api: api))
        currentToken.value = tokenNow
        let box = currentToken
        let gate = APIGate(token: { box.value }, mcp: mcp, extraOriginHosts: allInterfaces ? Self.localHostNames : []) { req in
            await api.handle(req)
        }
        let s = HTTPServer { req in await gate.handle(req) }
        s.onState = { [weak self] st in Task { @MainActor in self?.state = st } }
        server = s
        do { try s.start(port: UInt16(clamping: port), allInterfaces: allInterfaces) } catch { state = .failed(error.localizedDescription) }
    }

    func stop() {
        server?.stop()
        server = nil
        state = .stopped
    }

    func restart() {
        guard api != nil else { return }
        if enabled { start() } else { stop() }
    }

    var baseURL: String { "http://\(allInterfaces ? Self.hostName : "127.0.0.1"):\(port)" }

    var statusText: String {
        switch state {
        case .stopped: enabled ? "Starting…" : "Off"
        case .starting: "Starting…"
        case .listening(let p): "Listening on \(allInterfaces ? "every network interface" : "127.0.0.1 (this Mac only)"), port \(p)"
        case .failed(let e): "Couldn’t start: \(e)"
        }
    }

    var claudeCommand: String {
        "claude mcp add --transport http parts-inventory \(baseURL)/mcp --header \"Authorization: Bearer \(token)\""
    }
    var curlExample: String {
        "curl -H \"Authorization: Bearer \(token)\" \"\(baseURL)/api/parts?q=10k%200603\""
    }

    static let instructions = """
        The user's electronic parts inventory (the Parts Inventory app). Use search_parts before adding a part, to avoid duplicates; \
        add stock to an existing part with adjust_stock. add_part with lookup fills in details from Digi-Key and Mouser. \
        Locations are paths like "Cabinet A / Drawer 3". Ask before delete_part.
        """

    static var hostName: String {
        let h = ProcessInfo.processInfo.hostName
        return h.isEmpty ? "localhost" : h
    }
    static var localHostNames: Set<String> {
        let h = ProcessInfo.processInfo.hostName.lowercased()
        return h.isEmpty ? [] : [h, h.replacingOccurrences(of: ".local", with: "")]
    }
}

/// A value read on one queue and written on another.
nonisolated final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""
    var value: String {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
