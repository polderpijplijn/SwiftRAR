// SPDX-License-Identifier: MIT

/// Canonical Huffman decoder built from code lengths (0 = symbol unused).
///
/// Shorter codes first, ascending symbol number within a length: the
/// convention of RAR, Deflate and nearly every other format. Over-subscribed
/// length tables are rejected; incomplete ones are allowed, but a code that
/// falls into the gap throws instead of yielding an arbitrary symbol.
public struct HuffmanTable: Sendable {
    public static let maxCodeLength = 15

    /// Number of codes per length (index 0 unused).
    private let counts: [Int]
    /// Symbols sorted by (length, symbol number).
    private let symbols: [Int]

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
        self.counts = counts
        self.symbols = symbols
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
}
