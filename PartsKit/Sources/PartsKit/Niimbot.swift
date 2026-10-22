// NIIMBOT label printer protocol: packets, replies, the printer models and how each one prints.
//
// Ported from NiimBlue's niimbluelib (MIT, © 2024 MultiMote — github.com/MultiMote/niimbluelib):
// packets/packet.ts, commands.ts, packet_generator.ts, packet_parser.ts, print_tasks/*, utils/image_encoder.ts
// and printer_models.ts. Only what's needed to read a printer and print single-colour labels.

import Foundation

// MARK: - Packets

/// One packet: `55 55 cmd len data… xor aa aa` (the Connect packet is sent with a leading `03`).
public struct NiimbotPacket: Equatable, Sendable, CustomStringConvertible {
    public var command: UInt8
    public var data: [UInt8]
    /// Reply ids this request waits for; empty for a one-way packet (image rows).
    public var replies: [UInt8]

    public init(_ command: UInt8, _ data: [UInt8] = [1], replies: [UInt8]? = nil) {
        self.command = command
        self.data = data
        self.replies = replies ?? NiimbotCommand.replies[command] ?? []
    }

    public var oneWay: Bool { replies.isEmpty }

    public var checksum: UInt8 { data.reduce(command ^ UInt8(truncatingIfNeeded: data.count), ^) }

    public var bytes: [UInt8] {
        let raw = [0x55, 0x55, command, UInt8(truncatingIfNeeded: data.count)] + data + [checksum, 0xAA, 0xAA]
        return command == NiimbotCommand.connect ? [0x03] + raw : raw
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    public enum ParseError: Error, Equatable { case tooShort, badHead, badSize, badTail, badChecksum }

    /// One whole packet.
    public static func parse(_ b: [UInt8]) throws -> NiimbotPacket {
        guard b.count >= 7 else { throw ParseError.tooShort }
        guard b[0] == 0x55, b[1] == 0x55 else { throw ParseError.badHead }
        let len = Int(b[3])
        guard b.count == 7 + len else { throw ParseError.badSize }
        guard b[b.count - 2] == 0xAA, b[b.count - 1] == 0xAA else { throw ParseError.badTail }
        let p = NiimbotPacket(b[2], Array(b[4..<(4 + len)]), replies: [])
        guard p.checksum == b[4 + len] else { throw ParseError.badChecksum }
        return p
    }

    /// Split notifications into packets. Returns the whole packets and the bytes still waiting for more
    /// (a reply can arrive over several notifications). Rubbish that can't start a packet is dropped.
    public static func split(_ buffer: [UInt8]) -> (packets: [NiimbotPacket], rest: [UInt8]) {
        var out: [NiimbotPacket] = []
        var b = buffer[...]
        while !b.isEmpty {
            guard b.first == 0x55 else { return (out, []) }
            guard b.count >= 4 else { break }
            guard b[b.startIndex + 1] == 0x55 else { return (out, []) }
            let total = 7 + Int(b[b.startIndex + 3])
            guard b.count >= total else { break }
            guard let p = try? parse(Array(b.prefix(total))) else { return (out, []) }
            out.append(p)
            b = b.dropFirst(total)
        }
        return (out, Array(b))
    }
}

/// Command ids (requests to the printer, and its replies).
public enum NiimbotCommand {
    public static let connect: UInt8 = 0xC1
    public static let printEnd: UInt8 = 0xF3
    public static let pageStart: UInt8 = 0x03
    public static let pageEnd: UInt8 = 0xE3
    public static let printBitmapRow: UInt8 = 0x85
    public static let printBitmapRowIndexed: UInt8 = 0x83
    public static let printEmptyRow: UInt8 = 0x84
    public static let printClear: UInt8 = 0x20
    public static let printerInfo: UInt8 = 0x40
    public static let printerStatusData: UInt8 = 0xA5
    public static let printQuantity: UInt8 = 0x15
    public static let printStart: UInt8 = 0x01
    public static let printStatus: UInt8 = 0xA3
    public static let rfidInfo: UInt8 = 0x1A
    public static let setDensity: UInt8 = 0x21
    public static let setLabelType: UInt8 = 0x23
    public static let setPageSize: UInt8 = 0x13
    public static let heartbeat: UInt8 = 0xDC
    public static let getPaperInfo: UInt8 = 0x59
    public static let printerCheckLine: UInt8 = 0x86

    // replies
    public static let inNotSupported: UInt8 = 0x00
    public static let inPrintError: UInt8 = 0xDB
    public static let inPrinterPageIndex: UInt8 = 0xE0
    public static let inConnect: UInt8 = 0xC2
    public static let inPrintStatus: UInt8 = 0xB3
    public static let inPrintEnd: UInt8 = 0xF4
    public static let inPageStart: UInt8 = 0x04
    public static let inPageEnd: UInt8 = 0xE4
    public static let inRfidInfo: UInt8 = 0x1B
    public static let inPaperInfo: UInt8 = 0x69
    public static let inHeartbeatBasic: UInt8 = 0xDE
    public static let inHeartbeatPrinterInfo: UInt8 = 0xDF
    public static let inHeartbeatAdvanced1: UInt8 = 0xDD
    public static let inHeartbeatAdvanced2: UInt8 = 0xD9

    /// What each request waits for (from niimbluelib's commandsMap). Not listed: one-way.
    static let replies: [UInt8: [UInt8]] = [
        connect: [inConnect],
        printEnd: [inPrintEnd],
        pageStart: [inPageStart],
        pageEnd: [inPageEnd],
        printClear: [0x30],
        printerInfo: [0x4F, 0x47, 0x4D, 0x4A, 0x41, 0x4C, 0x43, 0x46, 0x48, 0x4B, 0x49, 0x42, 0x4E],
        printerStatusData: [0xB5],
        printQuantity: [0x16],
        printStart: [0x02],
        printStatus: [inPrintStatus],
        rfidInfo: [inRfidInfo],
        setDensity: [0x31],
        setLabelType: [0x33],
        setPageSize: [0x14],
        heartbeat: [inHeartbeatBasic, inHeartbeatPrinterInfo, inHeartbeatAdvanced1, inHeartbeatAdvanced2],
        getPaperInfo: [inPaperInfo],
        printerCheckLine: [0xD3],
    ]
}

/// What the printer can be asked with PrinterInfo (0x40).
public enum NiimbotInfo: UInt8, Sendable {
    case density = 1, speed = 2, labelType = 3, language = 6, autoShutdownTime = 7, modelId = 8, softwareVersion = 9
    case battery = 10, serialNumber = 11, hardwareVersion = 12, bluetoothAddress = 13, printMode = 14, area = 15
}

/// The kind of label stock (SetLabelType, and the RFID tag's consumables type).
public enum NiimbotLabelType: UInt8, Sendable, CaseIterable, Codable {
    case invalid = 0, withGaps = 1, black = 2, continuous = 3, perforated = 4, transparent = 5, pvcTag = 6, blackMarkGap = 10, heatShrinkTube = 11

    public var name: String {
        switch self {
        case .invalid: "unknown"
        case .withGaps: "labels with gaps"
        case .black: "black-mark labels"
        case .continuous: "continuous tape"
        case .perforated: "perforated labels"
        case .transparent: "transparent labels"
        case .pvcTag: "PVC tags"
        case .blackMarkGap: "black-mark labels with gaps"
        case .heatShrinkTube: "heat-shrink tube"
        }
    }
}

/// Packet builders (niimbluelib's PacketGenerator).
public enum NiimbotPackets {
    static func u16(_ n: Int) -> [UInt8] { [UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }

    public static func connect() -> NiimbotPacket { NiimbotPacket(NiimbotCommand.connect) }
    public static func printerStatusData() -> NiimbotPacket { NiimbotPacket(NiimbotCommand.printerStatusData) }
    public static func info(_ what: NiimbotInfo) -> NiimbotPacket { NiimbotPacket(NiimbotCommand.printerInfo, [what.rawValue]) }
    public static func heartbeat(_ type: UInt8) -> NiimbotPacket { NiimbotPacket(NiimbotCommand.heartbeat, [type]) }
    public static func rfidInfo() -> NiimbotPacket { NiimbotPacket(NiimbotCommand.rfidInfo) }
    public static func paperInfo() -> NiimbotPacket { NiimbotPacket(NiimbotCommand.getPaperInfo) }
    public static func setDensity(_ v: Int) -> NiimbotPacket { NiimbotPacket(NiimbotCommand.setDensity, [UInt8(clamping: v)]) }
    public static func setLabelType(_ t: NiimbotLabelType) -> NiimbotPacket { NiimbotPacket(NiimbotCommand.setLabelType, [t.rawValue]) }
    public static func printStart1b() -> NiimbotPacket { NiimbotPacket(NiimbotCommand.printStart) }
    public static func printStart2b(_ pages: Int) -> NiimbotPacket { NiimbotPacket(NiimbotCommand.printStart, u16(pages)) }
    public static func printStart7b(_ pages: Int) -> NiimbotPacket { NiimbotPacket(NiimbotCommand.printStart, u16(pages) + [0, 0, 0, 0, 0]) }
    public static func printStart9b(_ pages: Int, speed: UInt8 = 1) -> NiimbotPacket {
        NiimbotPacket(NiimbotCommand.printStart, u16(pages) + [0, 0, 0, 0, 0, speed, 0])
    }
    public static func pageStart() -> NiimbotPacket { NiimbotPacket(NiimbotCommand.pageStart) }
    public static func pageEnd() -> NiimbotPacket { NiimbotPacket(NiimbotCommand.pageEnd) }
    public static func printEnd() -> NiimbotPacket { NiimbotPacket(NiimbotCommand.printEnd) }
    public static func printClear() -> NiimbotPacket { NiimbotPacket(NiimbotCommand.printClear) }
    public static func printStatus(oneWay: Bool = false) -> NiimbotPacket {
        NiimbotPacket(NiimbotCommand.printStatus, [1], replies: oneWay ? [] : nil)
    }
    public static func printQuantity(_ n: Int) -> NiimbotPacket { NiimbotPacket(NiimbotCommand.printQuantity, u16(n)) }
    public static func pageSize2b(rows: Int) -> NiimbotPacket { NiimbotPacket(NiimbotCommand.setPageSize, u16(rows)) }
    public static func pageSize4b(rows: Int, cols: Int) -> NiimbotPacket { NiimbotPacket(NiimbotCommand.setPageSize, u16(rows) + u16(cols)) }
    public static func pageSize6b(rows: Int, cols: Int, copies: Int) -> NiimbotPacket {
        NiimbotPacket(NiimbotCommand.setPageSize, u16(rows) + u16(cols) + u16(copies))
    }
    public static func pageSize9b(rows: Int, cols: Int, copies: Int) -> NiimbotPacket {
        NiimbotPacket(NiimbotCommand.setPageSize, u16(rows) + u16(cols) + u16(copies) + u16(0) + [0])
    }
    public static func pageSize13b(rows: Int, cols: Int, copies: Int) -> NiimbotPacket {
        NiimbotPacket(NiimbotCommand.setPageSize, u16(rows) + u16(cols) + u16(copies) + u16(0) + [0, 0, 0] + u16(0))
    }
    public static func emptyRows(at row: Int, repeat n: Int) -> NiimbotPacket {
        NiimbotPacket(NiimbotCommand.printEmptyRow, u16(row) + [UInt8(n)], replies: [])
    }
    public static func checkLine(_ row: Int) -> NiimbotPacket { NiimbotPacket(NiimbotCommand.printerCheckLine, u16(row) + [1]) }

    /// A row of pixels; rows with ≤ 6 black dots are sent as their dots' positions instead.
    public static func row(_ r: NiimbotImage.Row, printhead: Int, counts: NiimbotImage.CountsMode = .auto, noIndex: Bool = false) -> NiimbotPacket {
        let c = NiimbotImage.countPixels(r.data, printhead: printhead, mode: counts)
        if c.total <= 6 && !noIndex {
            return NiimbotPacket(NiimbotCommand.printBitmapRowIndexed, u16(r.row) + c.parts + [UInt8(r.repeats)] + NiimbotImage.indexPixels(r.data), replies: [])
        }
        return NiimbotPacket(NiimbotCommand.printBitmapRow, u16(r.row) + c.parts + [UInt8(r.repeats)] + r.data, replies: [])
    }
}

// MARK: - Replies

public enum NiimbotReplies {
    public struct Error: LocalizedError, Equatable, Sendable {
        public var code: Int
        public var message: String
        public var errorDescription: String? { message }
    }

    /// A PrintError (0xdb) or NotSupported (0x00) reply as an error.
    public static func error(in p: NiimbotPacket) -> Error? {
        if p.command == NiimbotCommand.inPrintError {
            let code = Int(p.data.first ?? 0)
            return Error(code: code, message: "The printer reported: \(errorName(code)).")
        }
        if p.command == NiimbotCommand.inNotSupported { return Error(code: 0, message: "The printer doesn’t support that.") }
        return nil
    }

    public static func errorName(_ code: Int) -> String {
        switch code {
        case 0x01: "the cover is open"
        case 0x02: "no labels"
        case 0x03: "the battery is low"
        case 0x04: "battery fault"
        case 0x05: "cancelled"
        case 0x06: "bad print data"
        case 0x07: "overheated"
        case 0x08: "paper out"
        case 0x09: "busy"
        case 0x0A: "no print head"
        case 0x0B: "too cold"
        case 0x0C: "print head loose"
        case 0x0D: "no ribbon"
        case 0x0E: "wrong ribbon"
        case 0x0F: "used ribbon"
        case 0x10: "wrong labels"
        case 0x11: "couldn’t set the labels"
        case 0x12: "couldn’t set the print mode"
        case 0x13: "couldn’t set the darkness"
        case 0x17: "disconnected"
        case 0x18: "the label is the wrong size"
        case 0x32: "illegal page"
        case 0x34: "timed out receiving data"
        default: "error \(code)"
        }
    }

    public static func bool(_ p: NiimbotPacket) -> Bool { p.data.count == 1 && p.data[0] == 1 }

    /// Connect: 1 connected, 2 connected (protocol 1), 3 connected (ask PrinterStatusData), 90 firmware errors.
    public static func connectResult(_ p: NiimbotPacket) -> Int { Int(p.data.first ?? 0) }

    /// PrinterStatusData: protocol version (3, 4 or 5) from the firmware number at bytes 11–12.
    public static func protocolVersion(_ p: NiimbotPacket) -> Int {
        guard p.data.count >= 13 else { return 0 }
        let n = Int(p.data[11]) * 100 + Int(p.data[12])
        switch n {
        case 204..<300: return 3
        case 300..<302: return 4
        case 302...: return 5
        default: return 0
        }
    }

    public static func modelId(_ p: NiimbotPacket) -> Int? {
        switch p.data.count {
        case 1: Int(p.data[0]) << 8
        case 2: Int(p.data[0]) << 8 | Int(p.data[1])
        default: nil
        }
    }

    public static func byte(_ p: NiimbotPacket) -> Int? { p.data.count == 1 ? Int(p.data[0]) : nil }

    public static func battery(_ p: NiimbotPacket) -> Int? {
        guard let v = byte(p) else { return nil }
        return v <= 4 ? v * 25 : v
    }

    /// HeartbeatBasic reply to a PrinterInfo heartbeat: versions and the print head's width in dots.
    public struct HeadInfo: Equatable, Sendable {
        public var hardware: String
        public var software: String
        public var printheadWidth: Int
        public var resolutionClass: Int
        public var supportsRFID: Bool
    }

    public static func headInfo(_ p: NiimbotPacket) -> HeadInfo? {
        guard p.data.count == 10 else { return nil }
        let d = p.data
        func v(_ h: UInt8, _ l: UInt8) -> String { String(format: "%.2f", Double(l) / 100 + Double(h)) }
        return HeadInfo(hardware: v(d[0], d[1]), software: v(d[2], d[3]), printheadWidth: Int(d[4]) << 8 | Int(d[5]),
                        resolutionClass: Int(d[6]), supportsRFID: d[8] != 0)
    }

    /// The label roll's RFID tag.
    public struct Rfid: Equatable, Sendable {
        public var barCode: String
        public var serial: String
        public var total: Int
        public var used: Int
        public var type: NiimbotLabelType
        public var remaining: Int? { total > 0 ? max(0, total - used) : nil }
    }

    public static func rfid(_ p: NiimbotPacket) -> Rfid? {
        guard p.data.count > 1 else { return nil }
        var r = Reader(p.data)
        guard r.skip(8), let bar = r.vString(), let serial = r.vString(), let all = r.u16(), let used = r.u16(), let type = r.u8() else { return nil }
        return Rfid(barCode: bar, serial: serial, total: all, used: used, type: NiimbotLabelType(rawValue: UInt8(type)) ?? .invalid)
    }

    /// GetPaperInfo (newer printers): the loaded label's size in mm.
    public struct Paper: Equatable, Sendable {
        public var widthMM: Double
        public var heightMM: Double
        public var gapMM: Double
        public var type: NiimbotLabelType
    }

    public static func paper(_ p: NiimbotPacket, heightIncludesGap: Bool = false) -> Paper? {
        guard p.data.count == 18 else { return nil }
        var r = Reader(p.data)
        guard r.skip(4), let type = r.u8(), let gap = r.u16(), let total = r.u16(), r.skip(2), let width = r.u16() else { return nil }
        let g = Double(gap) / 10, h = Double(total) / 10 - (heightIncludesGap ? g : 0)
        return Paper(widthMM: Double(width) / 10, heightMM: h, gapMM: g, type: NiimbotLabelType(rawValue: UInt8(type)) ?? .invalid)
    }

    public struct PrintStatus: Equatable, Sendable {
        public var page: Int
        public var printProgress: Int
        public var feedProgress: Int
        public var error: Int
    }

    public static func printStatus(_ p: NiimbotPacket) -> PrintStatus? {
        guard p.data.count >= 4 else { return nil }
        let d = p.data
        return PrintStatus(page: Int(d[0]) << 8 | Int(d[1]), printProgress: Int(d[2]), feedProgress: Int(d[3]),
                           error: d.count == 10 ? Int(d[6]) : 0)
    }

    /// Heartbeat (Advanced 1 or 2): battery and whether labels are in.
    public struct Heartbeat: Equatable, Sendable {
        public var battery: Int?
        public var paperInserted: Bool?
        public var lidClosed: Bool?
    }

    public static func heartbeat(_ p: NiimbotPacket) -> Heartbeat? {
        let d = p.data
        func pct(_ v: UInt8) -> Int { v <= 4 ? Int(v) * 25 : Int(v) }
        if p.command == NiimbotCommand.inHeartbeatAdvanced2, d.count >= 9 {
            return Heartbeat(battery: pct(d[2]), paperInserted: d[5] == 0, lidClosed: d[4] == 0)
        }
        guard p.command == NiimbotCommand.inHeartbeatAdvanced1 else { return nil }
        switch d.count {
        case 10: return Heartbeat(battery: pct(d[9]), paperInserted: nil, lidClosed: nil)
        case 13: return Heartbeat(battery: pct(d[10]), paperInserted: d[11] == 0, lidClosed: nil)
        case 19: return Heartbeat(battery: pct(d[16]), paperInserted: d[17] == 0, lidClosed: nil)
        case 20: return Heartbeat(battery: nil, paperInserted: d[18] == 0, lidClosed: nil)
        default: return nil
        }
    }

    struct Reader {
        let d: [UInt8]
        var i = 0
        init(_ d: [UInt8]) { self.d = d }
        mutating func skip(_ n: Int) -> Bool { guard i + n <= d.count else { return false }; i += n; return true }
        mutating func u8() -> Int? { guard i < d.count else { return nil }; defer { i += 1 }; return Int(d[i]) }
        mutating func u16() -> Int? { guard i + 2 <= d.count else { return nil }; defer { i += 2 }; return Int(d[i]) << 8 | Int(d[i + 1]) }
        mutating func vString() -> String? {
            guard let n = u8(), n < 128, i + n <= d.count else { return nil }
            defer { i += n }
            return String(decoding: d[i..<(i + n)], as: UTF8.self)
        }
    }
}

// MARK: - Printer models

public enum NiimbotDirection: String, Sendable, Codable {
    /// The label runs sideways under the head (D11, D110, H1…): the image is turned a quarter turn clockwise.
    case left
    /// The label feeds top first (B1, B21, B3S…).
    case top
}

/// How a model prints (niimbluelib's print tasks).
public enum NiimbotPrintTask: String, Sendable, CaseIterable {
    case d11V1, d110, b1, b21V1, b21L2B, d110mV4, h1s
}

public struct NiimbotModel: Equatable, Sendable, Identifiable {
    public var name: String
    public var ids: [Int]
    public var dpi: Int
    public var direction: NiimbotDirection
    public var printheadPixels: Int
    public var paperTypes: [NiimbotLabelType]
    public var densityMin: Int
    public var densityMax: Int
    public var densityDefault: Int
    public var id: String { name }

    /// The printer's name for people: "B21 Pro" for "B21_PRO".
    public var displayName: String { name.replacingOccurrences(of: "_PRO", with: " Pro").replacingOccurrences(of: "_", with: " ") }
    /// Widest label across the head, mm.
    public var headMM: Double { Double(printheadPixels) * 25.4 / Double(dpi) }
    /// The small ones: 12–15 mm labels fed sideways.
    public var isSmall: Bool { direction == .left }

    /// The print algorithm: by model, then protocol version (niimbluelib's findPrintTask).
    public func printTask(protocolVersion: Int?) -> NiimbotPrintTask {
        let exact: [String: [Int: NiimbotPrintTask]] = ["D110_M": [4: .d110mV4], "D11": [1: .d110, 2: .d110]]
        if let v = protocolVersion, let t = exact[name]?[v] { return t }
        let byModel: [NiimbotPrintTask: [String]] = [
            .d11V1: ["D11", "D11S"], .b21V1: ["B21"], .b21L2B: ["B21_L2B"],
            .d110: ["B21S", "B21S_C2B", "D110"],
            .b1: ["D110_M", "B1", "B21_C2B", "M2_H", "N1", "D101"],
            .d110mV4: ["D11_H", "B21_PRO", "B1_PRO", "C1", "EP1C"],
            .h1s: ["H1S"],
        ]
        for t in NiimbotPrintTask.allCases where byModel[t]?.contains(name) == true { return t }
        if let v = protocolVersion, v >= 4 { return .d110mV4 }
        // Not in niimbluelib's table: the closest family.
        return direction == .left ? .d110 : .b1
    }

    public static func named(_ name: String) -> NiimbotModel? { library.first { $0.name == name } }
    public static func byId(_ id: Int) -> NiimbotModel? { library.first { $0.ids.contains(id) } }

    /// A model from a Bluetooth name: "B1-G327071185", "D110-A0123…", "B21_PRO-…".
    public static func fromDeviceName(_ name: String) -> NiimbotModel? {
        let head = name.uppercased().split(whereSeparator: { $0 == "-" || $0 == " " }).first.map(String.init) ?? ""
        let key = head.replacingOccurrences(of: "_", with: "")
        return library.first { $0.name.replacingOccurrences(of: "_", with: "") == key }
    }

    /// Before the printer says which it is: the D110, the most common small one.
    public static let fallback = named("D110")!

    // niimbluelib printer_models.ts: name, ids, dpi, direction, print head dots, label types, darkness min/max/default.
    public static let library: [NiimbotModel] = {
        typealias L = NiimbotLabelType
        func m(_ n: String, _ ids: [Int], _ dpi: Int, _ d: NiimbotDirection, _ head: Int, _ t: [L], _ dn: Int, _ dx: Int, _ dd: Int) -> NiimbotModel {
            NiimbotModel(name: n, ids: ids, dpi: dpi, direction: d, printheadPixels: head, paperTypes: t, densityMin: dn, densityMax: dx, densityDefault: dd)
        }
        let gbt: [L] = [.withGaps, .black, .transparent], gt: [L] = [.withGaps, .transparent]
        let gbct: [L] = [.withGaps, .black, .continuous, .transparent], gbcp: [L] = [.withGaps, .black, .continuous, .perforated]
        return [
            m("A1_PRO", [7424], 300, .left, 296, [.perforated, .continuous], 1, 5, 3),
            m("A20", [2817], 203, .top, 400, gbt, 1, 5, 3),
            m("A203", [2818], 203, .top, 400, gbt, 1, 5, 3),
            m("A63", [2054], 300, .top, 851, gbt, 1, 15, 10),
            m("A8", [256], 203, .top, 576, [.black, .withGaps, .continuous], 1, 5, 3),
            m("A8_P", [273], 203, .top, 576, gbt, 1, 5, 3),
            m("B1", [4096], 203, .top, 384, gbt, 1, 5, 3),
            m("B1_PRO", [4097], 300, .top, 567, gbt, 1, 5, 3),
            m("B1_SE", [4098], 203, .top, 384, gbt, 1, 5, 3),
            m("B11", [51457], 203, .top, 384, [.withGaps, .black, .continuous, .perforated, .transparent], 6, 15, 10),
            m("B16", [1792], 203, .left, 96, gt, 1, 3, 2),
            m("B18", [3584], 203, .left, 96, [.withGaps, .transparent, .blackMarkGap, .heatShrinkTube, .continuous], 1, 3, 2),
            m("B18S", [3585], 203, .left, 96, [.withGaps, .transparent, .blackMarkGap, .heatShrinkTube, .continuous], 1, 3, 2),
            m("B2", [6913], 203, .top, 384, gbt, 1, 5, 3),
            m("B2_PRO", [6912], 300, .top, 567, gbt, 1, 5, 3),
            m("B203", [2816], 203, .top, 400, gbt, 1, 5, 3),
            m("B21", [768], 203, .top, 384, gbct, 1, 5, 3),
            m("B21_PRO", [785], 300, .top, 591, gbct, 1, 5, 3),
            m("B21_C2B", [771, 775], 203, .top, 384, gbct, 1, 5, 3),
            m("B21_L2B", [769], 203, .top, 384, gbt, 1, 5, 3),
            m("B21S", [777], 203, .top, 384, gbct, 1, 5, 3),
            m("B21S_C2B", [776], 203, .top, 384, gbt, 1, 5, 3),
            m("B3", [52993], 203, .top, 600, gbct, 1, 5, 3),
            m("B31", [5632], 203, .top, 600, gbt, 1, 5, 3),
            m("B32", [2049], 300, .top, 851, gt, 1, 15, 10),
            m("B32R", [2050], 300, .top, 851, [.withGaps], 1, 15, 10),
            m("B3S", [256, 260, 262], 203, .top, 576, gbct, 1, 5, 3),
            m("B3S_A", [275], 203, .top, 576, gbct, 1, 5, 3),
            m("B3S_P", [272], 203, .top, 576, gbct, 1, 5, 3),
            m("B4", [6656], 203, .top, 832, gbt, 1, 5, 3),
            m("B4_PRO", [6657], 300, .top, 1229, gbt, 1, 5, 3),
            m("B50", [51713], 203, .top, 400, gbcp, 6, 15, 10),
            m("B50W", [51714], 203, .top, 384, gbcp, 6, 15, 10),
            m("BETTY", [2561], 203, .left, 192, gt, 1, 3, 2),
            m("C1", [5120], 300, .left, 178, [.continuous], 1, 5, 3),
            m("D101", [2560], 203, .left, 192, gt, 1, 3, 2),
            m("D11", [512], 203, .left, 96, gt, 1, 3, 2),
            m("D11_H", [528], 300, .left, 142, gt, 1, 5, 3),
            m("D11_PRO", [531], 300, .left, 142, gt, 1, 5, 3),
            m("D110", [2304, 2305], 203, .left, 96, gt, 1, 3, 2),
            m("D110_M", [2320], 203, .left, 96, gt, 1, 5, 3),
            m("D11S", [514], 203, .left, 96, gt, 1, 3, 2),
            m("EP1C", [5121], 300, .left, 178, [.continuous], 1, 5, 3),
            m("EP2M_H", [4610], 300, .top, 567, [.withGaps, .transparent, .black, .blackMarkGap], 1, 5, 3),
            m("EP3M", [6402], 300, .top, 851, [.withGaps, .transparent, .black, .blackMarkGap], 1, 5, 3),
            m("ET10", [5376], 203, .top, 1600, [.continuous], 3, 3, 3),
            m("FUST", [513], 203, .left, 96, gt, 1, 5, 3),
            m("H1", [3840], 203, .left, 96, gt, 1, 3, 2),
            m("H1S", [4352], 203, .left, 96, [.withGaps, .continuous, .transparent], 1, 3, 2),
            m("JC_M90", [51461], 203, .top, 384, gbcp, 6, 15, 10),
            m("K2", [6144], 203, .top, 448, gbt, 1, 5, 3),
            m("K3", [4864], 203, .top, 640, gbt, 1, 5, 3),
            m("K3_ITD", [4868], 203, .top, 640, gbt, 1, 5, 3),
            m("K3_W", [4865], 203, .top, 640, gbt, 1, 5, 3),
            m("K4", [7168], 203, .top, 832, gbt, 1, 15, 7),
            m("M2_H", [4608], 300, .top, 567, [.withGaps, .transparent, .black, .blackMarkGap], 1, 5, 3),
            m("M3", [6400], 300, .top, 851, [.withGaps, .transparent, .black, .blackMarkGap], 1, 5, 3),
            m("MP3K", [4866], 203, .top, 640, gbt, 1, 5, 3),
            m("MP3K_W", [4867], 203, .top, 640, gbt, 1, 5, 3),
            m("N1", [3586], 203, .left, 96, [.withGaps, .heatShrinkTube, .transparent, .blackMarkGap, .continuous], 1, 3, 2),
            m("P1", [1024], 300, .left, 697, [.pvcTag], 1, 5, 3),
            m("P18", [1026], 300, .left, 662, [.pvcTag], 1, 5, 3),
            m("P1S", [1025], 300, .left, 662, [.pvcTag], 1, 5, 3),
            m("S1", [51458], 203, .top, 384, gbcp, 6, 15, 10),
            m("S3", [51460], 203, .top, 384, gbcp, 6, 15, 10),
            m("S6", [261, 259, 258, 257], 203, .top, 576, gbt, 1, 5, 3),
            m("S6_P", [274], 203, .top, 600, gt, 1, 5, 3),
            m("T2S", [53250], 203, .top, 832, [.withGaps, .black], 1, 20, 15),
            m("T6", [51715], 203, .top, 384, gbcp, 6, 15, 10),
            m("T7", [51717], 203, .top, 384, gbcp, 6, 15, 10),
            m("T8", [51718], 300, .top, 567, gbcp, 6, 15, 10),
            m("T8S", [2053], 300, .top, 851, [.withGaps], 1, 15, 10),
            m("TP2M_H", [4609], 300, .top, 591, gbt, 1, 5, 3),
            m("Z401", [2051], 300, .top, 851, gt, 1, 15, 10),
        ]
    }()
}

// MARK: - Images

/// A 1-bit picture, one bit per dot, rows packed most-significant bit first; set = black.
public struct Bitmap1: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public private(set) var bytes: [UInt8]
    public var rowBytes: Int { (width + 7) / 8 }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: ((width + 7) / 8) * height)
    }

    /// From a grey picture (0 black … 255 white, `width` per row): darker than `threshold` prints.
    public init(width: Int, height: Int, gray: [UInt8], threshold: UInt8 = 160) {
        self.init(width: width, height: height)
        for y in 0..<height { for x in 0..<width where gray[y * width + x] < threshold { self[x, y] = true } }
    }

    public subscript(x: Int, y: Int) -> Bool {
        get { bytes[y * rowBytes + x / 8] & (0x80 >> UInt8(x % 8)) != 0 }
        set {
            let i = y * rowBytes + x / 8, bit = UInt8(0x80) >> UInt8(x % 8)
            if newValue { bytes[i] |= bit } else { bytes[i] &= ~bit }
        }
    }

    public mutating func fill(x: Int, y: Int, w: Int, h: Int) {
        let x0 = max(0, x), x1 = min(width, x + w), y0 = max(0, y), y1 = min(height, y + h)
        guard x0 < x1, y0 < y1 else { return }
        for yy in y0..<y1 { for xx in x0..<x1 { self[xx, yy] = true } }
    }

    public var blackCount: Int { bytes.reduce(0) { $0 + $1.nonzeroBitCount } }
}

/// The picture in the printer's rows (niimbluelib's ImageEncoder).
public struct NiimbotImage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case void, pixels, check }
    public struct Row: Equatable, Sendable {
        public var kind: Kind
        public var row: Int
        public var repeats: Int
        public var black: Int
        public var data: [UInt8]
    }
    public enum CountsMode: Sendable { case auto, split, total }

    /// Dots per row (across the head), a multiple of 8.
    public let cols: Int
    /// Rows (along the feed).
    public let rows: Int
    public let data: [Row]

    /// Encode a picture drawn the way the label is read. `.left` turns it a quarter turn clockwise for a sideways head.
    public init(_ b: Bitmap1, direction: NiimbotDirection) {
        let srcCols = direction == .left ? b.height : b.width
        rows = direction == .left ? b.width : b.height
        cols = (srcCols + 7) / 8 * 8
        func dot(_ col: Int, _ row: Int) -> Bool {
            direction == .left ? b[row, b.height - 1 - col] : b[col, row]
        }
        var out: [Row] = []
        for r in 0..<rows {
            var bytes = [UInt8](repeating: 0, count: cols / 8), black = 0
            for c in 0..<srcCols where dot(c, r) {
                bytes[c / 8] |= 0x80 >> UInt8(c % 8)
                black += 1
            }
            let new = Row(kind: black == 0 ? .void : .pixels, row: r, repeats: 1, black: black, data: black == 0 ? [] : bytes)
            if let last = out.last, last.kind == new.kind, last.data == new.data, last.repeats < 255 {
                out[out.count - 1].repeats += 1
            } else {
                out.append(new)
            }
            if r > 0, r % 200 == 199 { out.append(Row(kind: .check, row: r, repeats: 0, black: 0, data: [])) }
        }
        data = out
    }

    /// Black-dot counts for a bitmap packet: three chunks of the head (`split`) or the total, little-endian (`total`).
    public static func countPixels(_ buf: [UInt8], printhead: Int, mode: CountsMode = .auto) -> (total: Int, parts: [UInt8]) {
        let chunk = printhead / 8 / 3
        var split = chunk > 0 && buf.count <= chunk * 3
        if mode == .total { split = false }
        var total = 0, parts = [0, 0, 0]
        for (i, v) in buf.enumerated() {
            let n = v.nonzeroBitCount
            total += n
            if split, n > 0, i / chunk < 3 { parts[i / chunk] += n }
        }
        if split { return (total, parts.map { UInt8(clamping: $0) }) }
        return (total, [0, UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF)])
    }

    /// Positions of the black dots, two bytes each.
    public static func indexPixels(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for (i, b) in data.enumerated() { for bit in 0..<8 where b & (0x80 >> UInt8(bit)) != 0 { out += NiimbotPackets.u16(i * 8 + bit) } }
        return out
    }

    /// The row packets.
    public func packets(printhead: Int, counts: CountsMode = .auto, checkLines: Bool = false) -> [NiimbotPacket] {
        data.compactMap { r in
            switch r.kind {
            case .pixels: NiimbotPackets.row(r, printhead: printhead, counts: counts)
            case .void: NiimbotPackets.emptyRows(at: r.row, repeat: r.repeats)
            case .check: checkLines ? NiimbotPackets.checkLine(r.row) : nil
            }
        }
    }
}

// MARK: - Print jobs

/// A print job as steps for a connection to carry out (it sends, waits for replies and polls).
public enum NiimbotStep: Equatable, Sendable {
    /// Send and wait for the reply (one-way packets just go).
    case send(NiimbotPacket)
    /// Send until the printer answers yes (B21 L2B's PageStart / PageEnd).
    case sendUntilTrue(NiimbotPacket, attempts: Int)
    /// Poll PrintStatus until the printer has done this many pages.
    case waitStatus(pages: Int)
    /// Wait for page-index notices until this page (old D11).
    case waitPageIndex(pages: Int)
    /// Send PrintEnd until the printer agrees (B21 v1).
    case waitPrintEnd
    /// PrintEnd.
    case end
}

public struct NiimbotPage: Sendable {
    public var image: NiimbotImage
    public var copies: Int
    public init(image: NiimbotImage, copies: Int) { self.image = image; self.copies = max(1, copies) }
}

public enum NiimbotJob {
    /// The steps to print these pages on this model (niimbluelib's print tasks).
    public static func steps(task: NiimbotPrintTask, pages: [NiimbotPage], density: Int, labelType: NiimbotLabelType, printhead: Int) -> [NiimbotStep] {
        let total = pages.reduce(0) { $0 + $1.copies }
        var s: [NiimbotStep] = []
        func send(_ ps: [NiimbotPacket]) { s += ps.map(NiimbotStep.send) }
        let density = NiimbotPackets.setDensity(density), type = NiimbotPackets.setLabelType(labelType)

        switch task {
        case .b1: send([density, type, NiimbotPackets.printStart7b(total)])
        case .h1s: send([density, type, NiimbotPackets.printStart2b(total)])
        case .d110mV4: send([type, density, NiimbotPackets.printStart9b(total)])
        case .d11V1, .d110, .b21V1, .b21L2B: send([density, type, NiimbotPackets.printStart1b()])
        }

        var printed = 0
        for page in pages {
            let img = page.image, n = page.copies
            let rows = img.packets(printhead: printhead)
            switch task {
            case .b1:
                send([NiimbotPackets.pageStart(), NiimbotPackets.pageSize6b(rows: img.rows, cols: img.cols, copies: n)] + rows + [NiimbotPackets.pageEnd()])
            case .h1s:
                send([NiimbotPackets.pageStart(), NiimbotPackets.pageSize9b(rows: img.rows, cols: img.cols, copies: n)] + rows + [NiimbotPackets.pageEnd()])
            case .d110:
                // The D110 takes one page at a time: wait for it before sending the next.
                send([NiimbotPackets.printClear(), NiimbotPackets.pageStart(), NiimbotPackets.pageSize4b(rows: img.rows, cols: img.cols),
                      NiimbotPackets.printQuantity(n)] + rows + [NiimbotPackets.pageEnd()])
                printed += n
                s.append(.waitStatus(pages: printed))
            case .d11V1:
                send([NiimbotPackets.printClear(), NiimbotPackets.pageStart(), NiimbotPackets.pageSize2b(rows: img.rows),
                      NiimbotPackets.printQuantity(n)] + rows + [NiimbotPackets.pageEnd()])
            case .d110mV4:
                send([NiimbotPackets.printStatus(oneWay: true), NiimbotPackets.pageSize13b(rows: img.rows, cols: img.cols, copies: n)] + rows + [NiimbotPackets.pageEnd()])
            case .b21V1:
                let checked = img.packets(printhead: printhead, counts: .total, checkLines: true)
                for _ in 0..<n { send([NiimbotPackets.pageStart(), NiimbotPackets.pageSize4b(rows: img.rows, cols: img.cols)] + checked + [NiimbotPackets.pageEnd()]) }
            case .b21L2B:
                let checked = img.packets(printhead: printhead, counts: .total, checkLines: true)
                for _ in 0..<n {
                    s.append(.sendUntilTrue(NiimbotPackets.pageStart(), attempts: 5))
                    send([NiimbotPackets.pageSize4b(rows: img.rows, cols: img.cols)] + checked)
                    s.append(.sendUntilTrue(NiimbotPackets.pageEnd(), attempts: 20))
                }
            }
        }

        switch task {
        case .b1, .h1s, .d110mV4: s.append(.waitStatus(pages: total))
        case .d11V1: s.append(.waitPageIndex(pages: total))
        case .b21V1: s.append(.waitPrintEnd)
        case .d110, .b21L2B: break
        }
        if task != .b21V1 { s.append(.end) }
        if task == .d110mV4 { s.append(.send(NiimbotPackets.heartbeat(1).oneWayCopy)) }
        return s
    }
}

extension NiimbotPacket {
    /// The same packet, not waiting for a reply.
    public var oneWayCopy: NiimbotPacket { NiimbotPacket(command, data, replies: []) }
}
