import Foundation

/// CRC-32 (IEEE 802.3, as ZIP and PNG use it).
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    public static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// A minimal ZIP writer: entries are stored (not compressed), which every reader accepts. No ZIP64, so
/// the archive must stay under 4 GB and 65,535 entries — far beyond an inventory.
public struct ZipWriter: Sendable {
    struct Entry { var name: Data; var crc: UInt32; var size: UInt32; var offset: UInt32 }
    private var out = Data()
    private var entries: [Entry] = []
    /// The time stamped on every entry (DOS time, two-second steps). Fixed, so the same files give the same archive.
    public var date: Date

    public init(date: Date = Date(timeIntervalSince1970: 315_532_800)) { self.date = date }   // 1980-01-01, the earliest DOS date

    public mutating func add(_ path: String, _ data: Data) {
        let name = Data(path.utf8)
        let e = Entry(name: name, crc: CRC32.checksum(data), size: UInt32(data.count), offset: UInt32(out.count))
        out.append(le32(0x0403_4B50))       // local file header
        out.append(le16(20))                // version needed: 2.0
        out.append(le16(0x0800))            // flags: names are UTF-8
        out.append(le16(0))                 // stored
        out.append(dosTime)
        out.append(le32(e.crc)); out.append(le32(e.size)); out.append(le32(e.size))
        out.append(le16(UInt16(name.count))); out.append(le16(0))
        out.append(name)
        out.append(data)
        entries.append(e)
    }

    /// The finished archive: the entries, the central directory and its end record.
    public func finished() -> Data {
        var d = out
        let start = UInt32(d.count)
        for e in entries {
            d.append(le32(0x0201_4B50))     // central directory header
            d.append(le16(20)); d.append(le16(20))   // made by, version needed
            d.append(le16(0x0800)); d.append(le16(0))
            d.append(dosTime)
            d.append(le32(e.crc)); d.append(le32(e.size)); d.append(le32(e.size))
            d.append(le16(UInt16(e.name.count))); d.append(le16(0)); d.append(le16(0))   // name, extra, comment lengths
            d.append(le16(0)); d.append(le16(0)); d.append(le32(0))                      // disk, internal and external attributes
            d.append(le32(e.offset))
            d.append(e.name)
        }
        let size = UInt32(d.count) - start
        d.append(le32(0x0605_4B50))         // end of central directory
        d.append(le16(0)); d.append(le16(0))
        d.append(le16(UInt16(entries.count))); d.append(le16(UInt16(entries.count)))
        d.append(le32(size)); d.append(le32(start))
        d.append(le16(0))
        return d
    }

    private var dosTime: Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return le16(time) + le16(day)
    }
}

func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]) }
