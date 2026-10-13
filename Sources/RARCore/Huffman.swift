// SPDX-License-Identifier: MIT

/// Canonical Huffman decoder built from code lengths (0 = symbol unused).
///
/// Shorter codes first, ascending symbol number within a length: the
/// convention of RAR, Deflate and nearly every other format. Over-subscribed
/// length tables are rejected; incomplete ones are allowed, but a code that
/// falls into the gap throws instead of yielding an arbitrary symbol.
public struct HuffmanTable: Sendable {
    public static let maxCodeLength = 15
    /// Codes up to this length decode with a single table lookup.
    public static let quickBits = 9

    /// Number of codes per length (index 0 unused).
    @usableFromInline let counts: [Int]
    /// Symbols sorted by (length, symbol number).
    @usableFromInline let symbols: [Int]
    /// First canonical code of each length.
    @usableFromInline let firstCode: [Int]
    /// Index in `symbols` of the first symbol of each length.
    @usableFromInline let firstIndex: [Int]
    /// Indexed by the next `quickBits` bits: `length << 12 | symbol`, or 0
    /// when the code is longer than `quickBits` (or falls into a gap).
    @usableFromInline let quick: [UInt16]

    /// A table without codes: every decode throws.
    public static let empty = HuffmanTable()

    private init() {
        counts = [Int](repeating: 0, count: Self.maxCodeLength + 1)
        symbols = []
        firstCode = counts
        firstIndex = counts
        quick = [UInt16](repeating: 0, count: 1 << Self.quickBits)
    }

    public init(codeLengths: [UInt8]) throws {
        var counts = [Int](repeating: 0, count: Self.maxCodeLength + 1)
        for length in codeLengths {
            guard Int(length) <= Self.maxCodeLength else {
                throw RARError.corruptHeader("huffman code length \(length) too long")
            }
            counts[Int(length)] += 1
        }
        counts[0] = 0

        // Over-subscribed: no prefix-free code exists with these lengths.
        var left = 1
        for length in 1...Self.maxCodeLength {
            left <<= 1
            left -= counts[length]
            if left < 0 { throw RARError.corruptHeader("huffman table over-subscribed") }
        }

        var offsets = [Int](repeating: 0, count: Self.maxCodeLength + 2)
        for length in 1...Self.maxCodeLength {
            offsets[length + 1] = offsets[length] + counts[length]
        }
        var symbols = [Int](repeating: 0, count: offsets[Self.maxCodeLength + 1])
        for (symbol, length) in codeLengths.enumerated() where length != 0 {
            symbols[offsets[Int(length)]] = symbol
            offsets[Int(length)] += 1
        }
        guard codeLengths.count <= 1 << 12 else {
            throw RARError.corruptHeader("huffman alphabet too large")
        }

        var firstCode = [Int](repeating: 0, count: Self.maxCodeLength + 1)
        var firstIndex = [Int](repeating: 0, count: Self.maxCodeLength + 1)
        var code = 0
        var index = 0
        for length in 1...Self.maxCodeLength {
            firstCode[length] = code
            firstIndex[length] = index
            code = (code + counts[length]) << 1
            index += counts[length]
        }

        var quick = [UInt16](repeating: 0, count: 1 << Self.quickBits)
        for length in 1...Self.quickBits {
            let span = 1 << (Self.quickBits - length)
            for rank in 0..<counts[length] {
                let entry = UInt16(length << 12 | symbols[firstIndex[length] + rank])
                let start = (firstCode[length] + rank) * span
                for slot in start..<(start + span) { quick[slot] = entry }
            }
        }

        self.counts = counts
        self.symbols = symbols
        self.firstCode = firstCode
        self.firstIndex = firstIndex
        self.quick = quick
    }

    public var isEmpty: Bool { symbols.isEmpty }

    /// Decodes one symbol; throws on an unknown code or too few bits.
    public func decodeSymbol(from reader: inout BitReader) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for length in 1...Self.maxCodeLength {
            code |= Int(try reader.readBit())
            let count = counts[length]
            // Canonical codes keep code >= first; the lower bound is checked anyway.
            let offset = code - first
            if offset >= 0 && offset < count {
                return symbols[index + offset]
            }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw RARError.corruptHeader("invalid huffman code")
    }

    /// Decodes one symbol from a stream; table-driven, so it costs one
    /// look-ahead and one skip per symbol. Throws `.corruptData` on an
    /// unknown code and `.truncated` when the code runs past the end.
    @inlinable
    public func decodeSymbol(from reader: inout StreamBitReader) throws -> Int {
        let bits = Int(try reader.peekBits(Self.maxCodeLength))
        let entry = quick[bits >> (Self.maxCodeLength - Self.quickBits)]
        if entry != 0 {
            try reader.skipBits(Int(entry >> 12))
            return Int(entry & 0xFFF)
        }
        for length in (Self.quickBits + 1)...Self.maxCodeLength {
            let offset = (bits >> (Self.maxCodeLength - length)) - firstCode[length]
            if offset >= 0 && offset < counts[length] {
                try reader.skipBits(length)
                return symbols[firstIndex[length] + offset]
            }
        }
        throw RARError.corruptData("invalid huffman code")
    }
}
