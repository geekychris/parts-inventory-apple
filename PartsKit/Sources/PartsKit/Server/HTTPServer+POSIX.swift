#if !canImport(Network)
import Dispatch
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(WinSDK)
import WinSDK
#endif

// HTTPServer's BSD-socket implementation: used wherever Network.framework doesn't exist (Linux,
// Windows, Android). One background thread accepts connections; each connection gets its own thread
// that blocks on read/write — this is a local developer/LAN tool, not a high-concurrency server, so
// thread-per-connection is simpler than wiring up a reactor and plenty fast for it. See PORTABILITY.md:
// the Windows branch is written to the documented Winsock2 API but, lacking a Windows toolchain here,
// its first real compile is the windows-latest CI job this change adds.

#if os(Windows)
typealias SocketFD = SOCKET
private let invalidSocketFD: SocketFD = INVALID_SOCKET
private func closeSocketFD(_ fd: SocketFD) { closesocket(fd) }
private func lastSocketError() -> Int32 { Int32(WSAGetLastError()) }
private func socketErrorIsAddrInUse(_ e: Int32) -> Bool { e == WSAEADDRINUSE }
private func socketErrorIsPermission(_ e: Int32) -> Bool { e == WSAEACCES }
private let socketsInitialized: Bool = {
    var data = WSADATA()
    _ = WSAStartup(0x0202, &data)
    return true
}()
private func initializeSocketsIfNeeded() { _ = socketsInitialized }
#else
typealias SocketFD = Int32
private let invalidSocketFD: SocketFD = -1
private func closeSocketFD(_ fd: SocketFD) { close(fd) }
private func lastSocketError() -> Int32 { errno }
private func socketErrorIsAddrInUse(_ e: Int32) -> Bool { e == EADDRINUSE }
private func socketErrorIsPermission(_ e: Int32) -> Bool { e == EACCES || e == EPERM }
private func initializeSocketsIfNeeded() {}
#endif

#if os(Windows)
private let socketStreamType = SOCK_STREAM
#else
private let socketStreamType = Int32(SOCK_STREAM.rawValue)
#endif

private func describeLastError(port: UInt16) -> String {
    let code = lastSocketError()
    if socketErrorIsAddrInUse(code) { return "Port \(port) is already in use." }
    if socketErrorIsPermission(code) { return "Not allowed to listen on port \(port)." }
    return "Couldn't listen on port \(port) (error \(code))."
}

/// sockaddr_in's wire layout (family, port, address, then zero padding) has been ABI-stable since
/// Berkeley sockets, on Windows too — reading and writing it as raw bytes at those fixed offsets
/// sidesteps any difference in how each platform's Swift overlay names the struct's fields.
private func makeSockAddrIn(port: UInt16, networkOrderAddress: UInt32) -> sockaddr_in {
    var addr = sockaddr_in()
    withUnsafeMutableBytes(of: &addr) { raw in
        raw.storeBytes(of: UInt16(AF_INET), toByteOffset: 0, as: UInt16.self)
        raw.storeBytes(of: port.bigEndian, toByteOffset: 2, as: UInt16.self)
        raw.storeBytes(of: networkOrderAddress, toByteOffset: 4, as: UInt32.self)
    }
    return addr
}

private func portFrom(_ addr: sockaddr_in) -> UInt16 {
    withUnsafeBytes(of: addr) { raw in UInt16(bigEndian: raw.load(fromByteOffset: 2, as: UInt16.self)) }
}

#if os(Windows)
private func setReuseAddr(_ fd: SocketFD) {
    var one: Int32 = 1
    _ = withUnsafeBytes(of: &one) { raw in
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, raw.bindMemory(to: CHAR.self).baseAddress, Int32(MemoryLayout<Int32>.size))
    }
}
private func bindSocket(_ fd: SocketFD, _ addr: sockaddr_in) -> Bool {
    var addr = addr
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in bind(fd, sa, Int32(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
}
private func localAddress(_ fd: SocketFD) -> sockaddr_in? {
    var addr = sockaddr_in()
    var len = Int32(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in getsockname(fd, sa, &len) == 0 }
    }
    return ok ? addr : nil
}
private func acceptConnection(_ fd: SocketFD) -> SocketFD? {
    var addr = sockaddr_in()
    var len = Int32(MemoryLayout<sockaddr_in>.size)
    let client = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in accept(fd, sa, &len) }
    }
    return client == invalidSocketFD ? nil : client
}
private func readSocket(_ fd: SocketFD, into buffer: inout [UInt8]) -> Int {
    buffer.withUnsafeMutableBytes { raw in Int(recv(fd, raw.bindMemory(to: CHAR.self).baseAddress, Int32(raw.count), 0)) }
}
private func writeSocket(_ fd: SocketFD, _ data: Data) -> Int {
    data.withUnsafeBytes { raw in Int(send(fd, raw.bindMemory(to: CHAR.self).baseAddress, Int32(raw.count), 0)) }
}
#else
private func setReuseAddr(_ fd: SocketFD) {
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
}
private func bindSocket(_ fd: SocketFD, _ addr: sockaddr_in) -> Bool {
    var addr = addr
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
}
private func localAddress(_ fd: SocketFD) -> sockaddr_in? {
    var addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in getsockname(fd, sa, &len) == 0 }
    }
    return ok ? addr : nil
}
private func acceptConnection(_ fd: SocketFD) -> SocketFD? {
    var addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let client = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in accept(fd, sa, &len) }
    }
    return client < 0 ? nil : client
}
private func readSocket(_ fd: SocketFD, into buffer: inout [UInt8]) -> Int {
    buffer.withUnsafeMutableBytes { raw in recv(fd, raw.baseAddress, raw.count, 0) }
}
private func writeSocket(_ fd: SocketFD, _ data: Data) -> Int {
    data.withUnsafeBytes { raw in send(fd, raw.baseAddress, raw.count, 0) }
}
#endif

final class POSIXListener: @unchecked Sendable {
    let fd: SocketFD
    let port: UInt16
    private let lock = NSLock()
    private var accepting = true

    init(fd: SocketFD, port: UInt16) { self.fd = fd; self.port = port }

    var isAccepting: Bool { lock.withLock { accepting } }
    func stopAccepting() { lock.withLock { accepting = false } }
}

/// Bridges the server's `async` handler to the blocking connection thread.
private final class ResponseBox: @unchecked Sendable {
    var value: HTTPResponse?
    let sem = DispatchSemaphore(value: 0)
}

extension HTTPServer {
    /// Start listening. Port 0 picks a free port (see `state`).
    public func start(port: UInt16, allInterfaces: Bool = false) throws {
        stop()
        set(.starting)
        initializeSocketsIfNeeded()
        let fd: SocketFD = socket(AF_INET, socketStreamType, 0)
        guard fd != invalidSocketFD else { set(.failed(describeLastError(port: port))); return }
        setReuseAddr(fd)
        let address: UInt32 = allInterfaces ? 0 : htonl(0x7F00_0001)   // 0.0.0.0 or 127.0.0.1
        guard bindSocket(fd, makeSockAddrIn(port: port, networkOrderAddress: address)) else {
            let message = describeLastError(port: port)
            closeSocketFD(fd)
            set(.failed(message))
            return
        }
        guard listen(fd, 64) == 0 else {
            let message = describeLastError(port: port)
            closeSocketFD(fd)
            set(.failed(message))
            return
        }
        let resolvedPort = localAddress(fd).map(portFrom) ?? port
        let l = POSIXListener(fd: fd, port: resolvedPort)
        lock.withLock { listener = l }
        set(.listening(port: resolvedPort))
        acceptLoop(l)
    }

    public func stop() {
        let l = lock.withLock { () -> POSIXListener? in defer { listener = nil }; return listener }
        guard let l else { return }
        l.stopAccepting()
        closeSocketFD(l.fd)
        set(.stopped)
    }

    // MARK: Connections

    private func acceptLoop(_ l: POSIXListener) {
        Thread { [weak self] in
            var consecutiveFailures = 0
            while l.isAccepting {
                guard let client = acceptConnection(l.fd) else {
                    guard l.isAccepting else { break }
                    // A persistent accept() error (e.g. EMFILE from fd exhaustion) would otherwise
                    // busy-spin this thread at 100% CPU until stop() is called; back off briefly
                    // instead of retrying immediately, growing the wait with repeated failures.
                    consecutiveFailures += 1
                    Thread.sleep(forTimeInterval: min(0.1, 0.001 * Double(consecutiveFailures)))
                    continue
                }
                consecutiveFailures = 0
                guard let self else { closeSocketFD(client); continue }
                self.handle(client)
            }
        }.start()
    }

    private func handle(_ fd: SocketFD) {
        Thread { [weak self] in
            defer { closeSocketFD(fd) }
            guard let self else { return }
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = readSocket(fd, into: &chunk)
                if n <= 0 { return }
                data.append(chunk, count: n)
                switch HTTPParser.parse(data, maxBody: self.maxBody) {
                case .complete(let req):
                    let res = req.method == "OPTIONS" ? HTTPResponse(status: 204, headers: [("Allow", "GET, POST, PATCH, DELETE")]) : self.respond(to: req)
                    _ = writeSocket(fd, res.serialized())
                    return
                case .failed(let res):
                    _ = writeSocket(fd, res.serialized())
                    return
                case .incomplete:
                    continue
                }
            }
        }.start()
    }

    private func respond(to req: HTTPRequest) -> HTTPResponse {
        let box = ResponseBox()
        let handler = self.handler
        Task { box.value = await handler(req); box.sem.signal() }
        box.sem.wait()
        return box.value ?? .error(500, "no response")
    }
}
#endif
