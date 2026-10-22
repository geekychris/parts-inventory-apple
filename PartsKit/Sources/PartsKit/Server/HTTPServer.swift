import Foundation
import Network

/// An HTTP/1.1 server on Network.framework: one request per connection, answered by `handler`.
/// Bound to 127.0.0.1 unless asked to listen on every interface.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public enum State: Sendable, Equatable {
        case stopped, starting
        case listening(port: UInt16)
        case failed(String)
    }

    private let handler: Handler
    private let queue = DispatchQueue(label: "partsinventory.http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _state: State = .stopped
    /// Told about every state change (on the server's queue).
    public var onState: (@Sendable (State) -> Void)?
    public var maxBody = 20 * 1024 * 1024

    public init(handler: @escaping Handler) { self.handler = handler }

    public var state: State { lock.withLock { _state } }

    private func set(_ s: State) {
        lock.withLock { _state = s }
        onState?(s)
    }

    /// Start listening. Port 0 picks a free port (see `state`).
    public func start(port: UInt16, allInterfaces: Bool = false) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        if !allInterfaces {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        }
        let l = allInterfaces ? try NWListener(using: params, on: nwPort) : try NWListener(using: params)
        l.stateUpdateHandler = { [weak self, weak l] s in
            guard let self else { return }
            switch s {
            case .ready: self.set(.listening(port: l?.port?.rawValue ?? port))
            case .failed(let e): self.set(.failed(Self.describe(e, port: port))); l?.cancel()
            case .cancelled: if case .failed = self.state {} else { self.set(.stopped) }
            case .setup, .waiting: self.set(.starting)
            @unknown default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        lock.withLock { listener = l }
        set(.starting)
        l.start(queue: queue)
    }

    public func stop() {
        let l = lock.withLock { () -> NWListener? in defer { listener = nil }; return listener }
        l?.cancel()
        if l != nil { set(.stopped) }
    }

    /// Wait (briefly) for the listener to be ready or to fail.
    public func waitUntilReady(timeout: TimeInterval = 3) async -> State {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .listening, .failed, .stopped: return state
            case .starting: try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return state
    }

    private static func describe(_ e: NWError, port: UInt16) -> String {
        if case .posix(let code) = e, code == .EADDRINUSE { return "Port \(port) is already in use." }
        if case .posix(let code) = e, code == .EACCES || code == .EPERM { return "Not allowed to listen on port \(port) (\(e.localizedDescription))." }
        return e.localizedDescription
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { c.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer, maxBody: self.maxBody) {
            case .complete(let req):
                let handler = self.handler
                Task {
                    let res = req.method == "OPTIONS" ? HTTPResponse(status: 204, headers: [("Allow", "GET, POST, PATCH, DELETE")]) : await handler(req)
                    self.send(res, on: c)
                }
            case .failed(let res):
                self.send(res, on: c)
            case .incomplete:
                if error != nil || isComplete { c.cancel() } else { self.receive(c, buffer: buffer) }
            }
        }
    }

    private func send(_ res: HTTPResponse, on c: NWConnection) {
        c.send(content: res.serialized(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}
