import Foundation

/// Raw DEFLATE (RFC 1951) decoding, for zip entries where Apple's Compression framework isn't there
/// (Linux, Windows). Small and unhurried, after zlib's puff.c: workbooks are a few hundred kilobytes.
enum Inflate {
    struct Bad: Error {}

    static func decode(_ input: [UInt8], expectedSize: Int = 0) throws -> [UInt8] {
        var s = State(input: input)
        s.out.reserveCapacity(expectedSize)
        var last = false
        while !last {
            last = try s.bits(1) == 1
            switch try s.bits(2) {
            case 0: try s.stored()
            case 1: try s.codes(Huffman.fixedLength, Huffman.fixedDistance)
            case 2: let (l, d) = try s.dynamicTables(); try s.codes(l, d)
            default: throw Bad()
            }
        }
        return s.out
    }

    /// A canonical Huffman code: how many codes of each length, and the symbols in code order.
    struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        init(lengths: [Int]) throws {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            // An over-subscribed set of lengths isn't a code (an incomplete one is allowed, as zlib allows).
            var left = 1
            for len in 1..<16 {
                left <<= 1; left -= count[len]
                if left < 0 { throw Bad() }
            }
            var offset = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offset[len + 1] = offset[len] + count[len] }
            for (sym, l) in lengths.enumerated() where l != 0 { symbol[offset[l]] = sym; offset[l] += 1 }
        }

        static let fixedLength = try! Huffman(lengths: (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })
        static let fixedDistance = try! Huffman(lengths: [Int](repeating: 5, count: 30))
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                           4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    struct State {
        let input: [UInt8]
        var pos = 0, bitBuf = 0, bitCount = 0
        var out: [UInt8] = []

        init(input: [UInt8]) { self.input = input }

        mutating func bits(_ need: Int) throws -> Int {
            var v = bitBuf
            while bitCount < need {
                guard pos < input.count else { throw Bad() }
                v |= Int(input[pos]) << bitCount; pos += 1; bitCount += 8
            }
            bitBuf = v >> need; bitCount -= need
            return v & ((1 << need) - 1)
        }

        mutating func stored() throws {
            bitBuf = 0; bitCount = 0
            guard pos + 4 <= input.count else { throw Bad() }
            let len = Int(input[pos]) | Int(input[pos + 1]) << 8
            let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
            guard len == ~nlen & 0xFFFF, pos + 4 + len <= input.count else { throw Bad() }
            out.append(contentsOf: input[(pos + 4)..<(pos + 4 + len)])
            pos += 4 + len
        }

        /// One symbol, read a bit at a time (Huffman codes are packed most significant bit first).
        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let n = h.count[len]
                if code - n < first { return h.symbol[index + (code - first)] }
                index += n; first += n; first <<= 1; code <<= 1
            }
            throw Bad()
        }

        mutating func codes(_ lencode: Huffman, _ distcode: Huffman) throws {
            while true {
                let sym = try decode(lencode)
                if sym < 256 { out.append(UInt8(sym)); continue }
                if sym == 256 { return }
                let li = sym - 257
                guard li < lengthBase.count else { throw Bad() }
                let len = lengthBase[li] + (try bits(lengthExtra[li]))
                let di = try decode(distcode)
                guard di < distBase.count else { throw Bad() }
                let dist = distBase[di] + (try bits(distExtra[di]))
                guard dist <= out.count else { throw Bad() }
                let from = out.count - dist
                for i in 0..<len { out.append(out[from + i]) }
            }
        }

        mutating func dynamicTables() throws -> (Huffman, Huffman) {
            let nlen = try bits(5) + 257, ndist = try bits(5) + 1, ncode = try bits(4) + 4
            guard nlen <= 286, ndist <= 30 else { throw Bad() }
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            var codeLengths = [Int](repeating: 0, count: 19)
            for i in 0..<ncode { codeLengths[order[i]] = try bits(3) }
            let lencode = try Huffman(lengths: codeLengths)
            var lengths: [Int] = []
            while lengths.count < nlen + ndist {
                let sym = try decode(lencode)
                switch sym {
                case 0..<16: lengths.append(sym)
                case 16:
                    guard let prev = lengths.last else { throw Bad() }
                    lengths += [Int](repeating: prev, count: 3 + (try bits(2)))
                case 17: lengths += [Int](repeating: 0, count: 3 + (try bits(3)))
                default: lengths += [Int](repeating: 0, count: 11 + (try bits(7)))
                }
            }
            guard lengths.count == nlen + ndist, lengths[256] != 0 else { throw Bad() }
            return (try Huffman(lengths: Array(lengths[0..<nlen])), try Huffman(lengths: Array(lengths[nlen...])))
        }
    }
}
