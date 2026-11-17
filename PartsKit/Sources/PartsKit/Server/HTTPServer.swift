import Foundation
#if canImport(Network)
import Network
#endif

/// An HTTP/1.1 server: one request per connection, answered by `handler`. Bound to 127.0.0.1 unless
/// asked to listen on every interface. On Apple platforms this is Network.framework
/// (HTTPServer+Apple.swift); everywhere else it's BSD sockets (HTTPServer+POSIX.swift) — see
/// PORTABILITY.md. Only this file's API is public; the two implementations share nothing but it.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public enum State: Sendable, Equatable {
        case stopped, starting
        case listening(port: UInt16)
        case failed(String)
    }

    let handler: Handler
    let queue = DispatchQueue(label: "partsinventory.http")
    let lock = NSLock()
    var _state: State = .stopped
    /// Told about every state change (on the server's queue).
    public var onState: (@Sendable (State) -> Void)?
    public var maxBody = 20 * 1024 * 1024

#if canImport(Network)
    var listener: NWListener?
#else
    var listener: POSIXListener?
#endif

    public init(handler: @escaping Handler) { self.handler = handler }

    public var state: State { lock.withLock { _state } }

    func set(_ s: State) {
        lock.withLock { _state = s }
        onState?(s)
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
}
