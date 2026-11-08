import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import Testing
@testable import PartsKit

// HTTPServer has two implementations (Network.framework on Apple platforms, BSD sockets everywhere
// else — see PORTABILITY.md) behind one public API. These tests exercise that API over real sockets
// so they say something about whichever implementation the test runner's OS actually compiled, not
// just that it compiled.

@Test func startsAndAnswersOverRealSockets() async throws {
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

@Test func reportsPortInUseAsFailed() async throws {
    let first = HTTPServer { _ in .empty(204) }
    try first.start(port: 0)
    defer { first.stop() }
    guard case .listening(let port) = await first.waitUntilReady() else { Issue.record("not listening: \(first.state)"); return }

    let second = HTTPServer { _ in .empty(204) }
    try second.start(port: port)
    defer { second.stop() }
    guard case .failed = await second.waitUntilReady() else { Issue.record("should have failed, got \(second.state)"); return }
}

@Test func stopClosesTheListener() async throws {
    let server = HTTPServer { _ in .empty(204) }
    try server.start(port: 0)
    guard case .listening(let port) = await server.waitUntilReady() else { Issue.record("not listening: \(server.state)"); return }
    server.stop()
    #expect(server.state == .stopped)

    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
    req.timeoutInterval = 3
    do {
        _ = try await URLSession.shared.data(for: req)
        Issue.record("expected the connection to be refused")
    } catch {
        // Connection refused (or similar) — the port is no longer listening.
    }
}

@Test func allInterfacesListensOnEveryAddress() async throws {
    guard let host = firstNonLoopbackIPv4() else { return }   // this sandbox only has loopback

    let loopbackOnly = HTTPServer { _ in .empty(204) }
    try loopbackOnly.start(port: 0)
    defer { loopbackOnly.stop() }
    guard case .listening(let p1) = await loopbackOnly.waitUntilReady() else { Issue.record("not listening: \(loopbackOnly.state)"); return }
    var blocked = URLRequest(url: URL(string: "http://\(host):\(p1)/")!)
    blocked.timeoutInterval = 3
    do { _ = try await URLSession.shared.data(for: blocked); Issue.record("loopback-only shouldn't answer on \(host)") } catch {}

    let everywhere = HTTPServer { _ in .empty(204) }
    try everywhere.start(port: 0, allInterfaces: true)
    defer { everywhere.stop() }
    guard case .listening(let p2) = await everywhere.waitUntilReady() else { Issue.record("not listening: \(everywhere.state)"); return }
    var allowed = URLRequest(url: URL(string: "http://\(host):\(p2)/")!)
    allowed.timeoutInterval = 3
    let (_, res) = try await URLSession.shared.data(for: allowed)
    #expect((res as? HTTPURLResponse)?.statusCode == 204)
}

/// A non-loopback IPv4 address this machine answers on, if it has one (most CI runners do; some
/// sandboxes only have loopback).
private func firstNonLoopbackIPv4() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(first) }
    var found: String?
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let ifa = p {
        defer { p = ifa.pointee.ifa_next }
        guard let sa = ifa.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET else { continue }
        let flags = UInt32(ifa.pointee.ifa_flags)
        guard flags & UInt32(IFF_LOOPBACK) == 0, flags & UInt32(IFF_UP) != 0 else { continue }
        var addr = UnsafeRawPointer(sa).load(as: sockaddr_in.self)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        found = buf.withUnsafeBufferPointer { String(decoding: UnsafeRawBufferPointer($0).prefix(while: { $0 != 0 }), as: UTF8.self) }
        break
    }
    return found
}
