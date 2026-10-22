// Talking to a NIIMBOT printer over Bluetooth LE: finding it, connecting, and the request/reply exchange.
// After NiimBlue's niimbluelib (MIT, © 2024 MultiMote): client/bluetooth_impl.ts, abstract_client.ts, packets/protocol.ts.

@preconcurrency import CoreBluetooth
import Foundation

/// A printer seen nearby.
public struct NiimbotDevice: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var rssi: Int
    public var modelName: String?
}

public struct NiimbotError: LocalizedError, Sendable {
    public var errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

/// The Bluetooth side: scanning, connecting, writing bytes and collecting reply packets. Everything
/// CoreBluetooth touches happens on one queue.
public final class NiimbotTransport: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    /// The service NIIMBOT printers offer; the channel is its characteristic that both notifies and takes writes.
    public static let service = CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2")

    private let q = DispatchQueue(label: "niimbot.bluetooth")
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var devices: [UUID: NiimbotDevice] = [:]
    private var peripheral: CBPeripheral?
    private var channel: CBCharacteristic?
    private var pendingServices = 0
    private var buffer: [UInt8] = []
    private var readyWaiters: [CheckedContinuation<CBManagerState, Never>] = []
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called on the Bluetooth queue.
    public var onDevices: (@Sendable ([NiimbotDevice]) -> Void)?
    public var onPackets: (@Sendable ([NiimbotPacket]) -> Void)?
    public var onDisconnect: (@Sendable (String?) -> Void)?

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: q)
    }

    public var state: CBManagerState { q.sync { central.state } }
    public var isConnected: Bool { q.sync { channel != nil && peripheral?.state == .connected } }
    public var connectedName: String? { q.sync { peripheral?.name } }

    /// Wait for Bluetooth to be on (or to say it can't be).
    public func ready(timeout: Double = 5) async -> CBManagerState {
        await withCheckedContinuation { c in
            q.async {
                if self.central.state != .unknown && self.central.state != .resetting { c.resume(returning: self.central.state); return }
                self.readyWaiters.append(c)
                self.q.asyncAfter(deadline: .now() + timeout) {
                    if !self.readyWaiters.isEmpty { self.readyWaiters.forEach { $0.resume(returning: self.central.state) }; self.readyWaiters = [] }
                }
            }
        }
    }

    public func startScan() {
        q.async {
            self.devices = [:]
            guard self.central.state == .poweredOn else { return }
            self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    public func stopScan() { q.async { if self.central.isScanning { self.central.stopScan() } } }

    /// Connect and find the channel. Works for a printer seen in this scan or one connected to before.
    public func connect(_ id: UUID, timeout: Double = 15) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            q.async {
                if self.central.isScanning { self.central.stopScan() }
                let known = self.peripherals[id] ?? self.central.retrievePeripherals(withIdentifiers: [id]).first
                guard let p = known else { c.resume(throwing: NiimbotError("That printer isn’t nearby — turn it on and look again.")); return }
                if let old = self.peripheral, old.identifier != id { self.central.cancelPeripheralConnection(old) }
                self.peripheral = p
                self.channel = nil
                self.buffer = []
                p.delegate = self
                self.connectWaiter = c
                self.central.connect(p)
                self.q.asyncAfter(deadline: .now() + timeout) {
                    guard let w = self.connectWaiter else { return }
                    self.connectWaiter = nil
                    self.central.cancelPeripheralConnection(p)
                    w.resume(throwing: NiimbotError("The printer didn’t answer. Is it on, and not connected to the NIIMBOT app?"))
                }
            }
        }
    }

    public func disconnect() {
        q.async {
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.channel = nil
        }
    }

    /// Write bytes, split to the link's size, waiting for room when the printer's buffer is full.
    public func write(_ bytes: [UInt8]) async throws {
        let (p, ch): (CBPeripheral?, CBCharacteristic?) = q.sync { (peripheral, channel) }
        guard let p, let ch else { throw NiimbotError("The printer isn’t connected.") }
        let size = max(20, p.maximumWriteValueLength(for: .withoutResponse))
        var i = 0
        while i < bytes.count {
            let chunk = Data(bytes[i..<min(bytes.count, i + size)])
            await waitForRoom()
            let ok: Bool = q.sync {
                guard self.channel != nil, p.state == .connected else { return false }
                p.writeValue(chunk, for: ch, type: .withoutResponse)
                return true
            }
            guard ok else { throw NiimbotError("The printer disconnected.") }
            i += size
        }
    }

    private func waitForRoom() async {
        await withCheckedContinuation { c in
            q.async {
                if self.peripheral?.canSendWriteWithoutResponse ?? true { c.resume() } else { self.writeWaiters.append(c) }
            }
        }
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .unknown && central.state != .resetting {
            readyWaiters.forEach { $0.resume(returning: central.state) }
            readyWaiters = []
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let model = NiimbotModel.fromDeviceName(name)
        guard model != nil || services.contains(Self.service) else { return }
        peripherals[p.identifier] = p
        devices[p.identifier] = NiimbotDevice(id: p.identifier, name: name.isEmpty ? "NIIMBOT printer" : name, rssi: rssi.intValue, modelName: model?.name)
        onDevices?(devices.values.sorted { $0.rssi > $1.rssi })
    }

    public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        failConnect(error?.localizedDescription ?? "Couldn’t connect to the printer.")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        channel = nil
        writeWaiters.forEach { $0.resume() }
        writeWaiters = []
        failConnect(error?.localizedDescription ?? "The printer disconnected.")
        onDisconnect?(error?.localizedDescription)
    }

    private func failConnect(_ message: String) {
        guard let w = connectWaiter else { return }
        connectWaiter = nil
        w.resume(throwing: NiimbotError(message))
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        // Only the long (vendor) services; the channel is in one of them.
        let services = (p.services ?? []).filter { $0.uuid.uuidString.count > 8 }
        pendingServices = services.count
        guard !services.isEmpty else { failConnect("This doesn’t look like a NIIMBOT printer."); central.cancelPeripheralConnection(p); return }
        services.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        pendingServices -= 1
        if channel == nil, let c = (s.characteristics ?? []).first(where: { $0.properties.contains(.notify) && $0.properties.contains(.writeWithoutResponse) }) {
            channel = c
            p.setNotifyValue(true, for: c)
            return
        }
        if pendingServices <= 0 && channel == nil {
            failConnect("The printer’s data channel wasn’t found.")
            central.cancelPeripheralConnection(p)
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c == channel, let w = connectWaiter else { return }
        connectWaiter = nil
        if let error { w.resume(throwing: NiimbotError(error.localizedDescription)) } else { w.resume() }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c == channel, let v = c.value, !v.isEmpty else { return }
        buffer += [UInt8](v)
        let (packets, rest) = NiimbotPacket.split(buffer)
        buffer = rest
        if !packets.isEmpty { onPackets?(packets) }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        let w = writeWaiters
        writeWaiters = []
        w.forEach { $0.resume() }
    }
}

/// A connected printer: one request at a time, each waiting for its reply.
public actor NiimbotSession {
    /// What the printer said about itself and what's loaded.
    public struct Info: Equatable, Sendable {
        public var deviceName: String
        public var modelId: Int?
        public var model: NiimbotModel?
        public var protocolVersion = 0
        public var head: NiimbotReplies.HeadInfo?
        public var battery: Int?
        public var serial: String?
        public var labelType: NiimbotLabelType?
        public var rfid: NiimbotReplies.Rfid?
        public var paper: NiimbotReplies.Paper?

        /// The model, or a stand-in built from what the printer reported.
        public var effectiveModel: NiimbotModel {
            if let model { return model }
            var m = NiimbotModel.fallback
            if let h = head { m.printheadPixels = h.printheadWidth; m.dpi = h.resolutionClass == 3 ? 300 : 203; m.direction = h.printheadWidth > 200 ? .top : .left }
            m.name = deviceName
            return m
        }
        /// The roll's size, when the printer can tell.
        public var rollSize: LabelSize? { paper.flatMap { LabelSize.fromPaper($0, model: effectiveModel) } }
        public var printTask: NiimbotPrintTask { effectiveModel.printTask(protocolVersion: protocolVersion) }
    }

    public nonisolated let transport: NiimbotTransport
    private var waiters: [(id: UUID, ids: [UInt8], c: CheckedContinuation<NiimbotPacket, Error>)] = []
    private var inbox: [NiimbotPacket] = []
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var pageIndex: Int?
    public private(set) var info: Info?

    public init(transport: NiimbotTransport) {
        self.transport = transport
        let (stream, cont) = AsyncStream.makeStream(of: [NiimbotPacket].self)
        transport.onPackets = { cont.yield($0) }
        Task { [weak self] in for await ps in stream { await self?.receive(ps) } }
    }

    // MARK: Requests

    private func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { queue.append($0) }
    }

    private func unlock() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }

    /// Send a packet and wait for its reply (one-way packets just go). A PrintError reply throws.
    @discardableResult
    public func send(_ p: NiimbotPacket, timeout: Double = 1) async throws -> NiimbotPacket? {
        await lock()
        defer { unlock() }
        return try await exchange(p, timeout: timeout)
    }

    private func exchange(_ p: NiimbotPacket, timeout: Double) async throws -> NiimbotPacket? {
        inbox = []
        try await Task.sleep(for: .milliseconds(10))  // niimbluelib's packet interval: some printers drop packets sent back to back
        try await transport.write(p.bytes)
        guard !p.oneWay else { return nil }
        return try await reply(p.replies, timeout: timeout)
    }

    private func matches(_ p: NiimbotPacket, _ ids: [UInt8]) -> Bool {
        ids.isEmpty || ids.contains(p.command) || p.command == NiimbotCommand.inPrintError || p.command == NiimbotCommand.inNotSupported
    }

    private func reply(_ ids: [UInt8], timeout: Double) async throws -> NiimbotPacket {
        if let i = inbox.firstIndex(where: { matches($0, ids) }) {
            let p = inbox.remove(at: i)
            if let e = NiimbotReplies.error(in: p) { throw e }
            return p
        }
        let id = UUID()
        let p: NiimbotPacket = try await withCheckedThrowingContinuation { c in
            waiters.append((id, ids, c))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id)
            }
        }
        if let e = NiimbotReplies.error(in: p) { throw e }
        return p
    }

    private func expire(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).c.resume(throwing: NiimbotError("The printer didn’t reply in time."))
    }

    private func receive(_ ps: [NiimbotPacket]) {
        for p in ps {
            if p.command == NiimbotCommand.inPrinterPageIndex, p.data.count == 2 { pageIndex = Int(p.data[0]) << 8 | Int(p.data[1]) }
            if let i = waiters.firstIndex(where: { matches(p, $0.ids) }) {
                waiters.remove(at: i).c.resume(returning: p)
            } else {
                inbox.append(p)
                if inbox.count > 32 { inbox.removeFirst() }
            }
        }
    }

    // MARK: Connecting

    /// Connect, agree the protocol and read what the printer is and what's loaded.
    public func connect(_ device: UUID, name: String) async throws -> Info {
        try await transport.connect(device)
        var i = Info(deviceName: name)
        guard let c = try await send(NiimbotPackets.connect(), timeout: 3) else { throw NiimbotError("No reply to Connect.") }
        switch NiimbotReplies.connectResult(c) {
        case 3: i.protocolVersion = await ask(NiimbotPackets.printerStatusData()).map(NiimbotReplies.protocolVersion) ?? 0
        case 2: i.protocolVersion = 1
        case 0: throw NiimbotError("The printer refused the connection.")
        default: break
        }
        if let r = try await send(NiimbotPackets.info(.modelId)), let id = NiimbotReplies.modelId(r) {
            i.modelId = id
            i.model = NiimbotModel.byId(id)
        }
        if i.model == nil { i.model = NiimbotModel.fromDeviceName(name) }
        i.head = await ask(NiimbotPackets.heartbeat(3)).flatMap(NiimbotReplies.headInfo)
        i.battery = await ask(NiimbotPackets.info(.battery)).flatMap(NiimbotReplies.battery)
        i.labelType = await ask(NiimbotPackets.info(.labelType)).flatMap(NiimbotReplies.byte).flatMap { NiimbotLabelType(rawValue: UInt8(clamping: $0)) }
        if let r = await ask(NiimbotPackets.info(.serialNumber)), r.data.count >= 8 { i.serial = String(decoding: r.data, as: UTF8.self) }
        info = i
        await refreshRoll()
        return info ?? i
    }

    /// A request whose failure doesn't matter (not every printer answers everything).
    private func ask(_ p: NiimbotPacket, timeout: Double = 1) async -> NiimbotPacket? {
        guard let r = try? await send(p, timeout: timeout) else { return nil }
        return r
    }

    /// Read the roll's RFID tag and, on printers that know it, its size.
    @discardableResult
    public func refreshRoll() async -> Info? {
        guard var i = info else { return nil }
        i.rfid = await ask(NiimbotPackets.rfidInfo()).flatMap(NiimbotReplies.rfid)
        let b21Pro = i.modelId == 785  // its paper height includes the gap
        i.paper = await ask(NiimbotPackets.paperInfo()).flatMap { NiimbotReplies.paper($0, heightIncludesGap: b21Pro) }
        info = i
        return i
    }

    /// Battery and whether labels are in.
    public func heartbeat() async -> NiimbotReplies.Heartbeat? {
        let type: UInt8 = (info?.protocolVersion ?? 0) >= 3 ? 4 : 1
        guard let r = await ask(NiimbotPackets.heartbeat(type), timeout: 0.8), let h = NiimbotReplies.heartbeat(r) else { return nil }
        if let b = h.battery { info?.battery = b }
        return h
    }

    // MARK: Printing

    /// Carry out a print job's steps. `progress` gets pages done of the total.
    public func run(_ steps: [NiimbotStep], total: Int, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws {
        await lock()
        defer { unlock() }
        pageIndex = nil
        do {
            for step in steps {
                switch step {
                case .send(let p):
                    _ = try await exchange(p, timeout: 10)
                case .sendUntilTrue(let p, let attempts):
                    var ok = false
                    for _ in 0..<attempts {
                        if let r = try? await exchange(p, timeout: 2), NiimbotReplies.bool(r) { ok = true; break }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    if !ok { throw NiimbotError("The printer didn’t accept the page.") }
                case .waitStatus(let pages):
                    try await waitStatus(pages, total: total, progress: progress)
                case .waitPageIndex(let pages):
                    var last = Date.now
                    while (pageIndex ?? 0) < pages {
                        let before = pageIndex
                        try await Task.sleep(for: .milliseconds(200))
                        if pageIndex != before { last = .now; progress(pageIndex ?? 0, total) }
                        if Date.now.timeIntervalSince(last) > 8 { throw NiimbotError("The printer stopped reporting pages.") }
                    }
                case .waitPrintEnd:
                    let start = Date.now
                    while true {
                        if let r = try? await exchange(NiimbotPackets.printEnd(), timeout: 2), NiimbotReplies.bool(r) { break }
                        if Date.now.timeIntervalSince(start) > 60 { throw NiimbotError("The printer didn’t finish.") }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                case .end:
                    _ = try? await exchange(NiimbotPackets.printEnd(), timeout: 2)
                }
            }
            progress(total, total)
        } catch {
            _ = try? await exchange(NiimbotPackets.printEnd(), timeout: 2)
            throw error
        }
    }

    private func waitStatus(_ pages: Int, total: Int, progress: @Sendable (Int, Int) -> Void) async throws {
        var lastChange = Date.now, last = (-1, -1, -1)
        while true {
            try await Task.sleep(for: .milliseconds(300))
            var status: NiimbotReplies.PrintStatus?
            for _ in 0..<2 where status == nil {
                if let r = try await exchange(NiimbotPackets.printStatus(), timeout: 5) { status = NiimbotReplies.printStatus(r) }
            }
            guard let s = status else { continue }
            if s.error != 0 { throw NiimbotReplies.Error(code: s.error, message: "The printer reported: \(NiimbotReplies.errorName(s.error)).") }
            progress(s.page, total)
            if s.page >= pages { return }
            if (s.page, s.printProgress, s.feedProgress) != last { last = (s.page, s.printProgress, s.feedProgress); lastChange = .now }
            if Date.now.timeIntervalSince(lastChange) > 20 { throw NiimbotError("The printer stopped part-way. Check the labels and the lid.") }
        }
    }
}
