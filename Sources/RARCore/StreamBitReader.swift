// SPDX-License-Identifier: MIT

/// Reads bits MSB-first from a byte range of a `ByteSource`, loading it in
/// chunks so that a compressed entry is never held in memory as a whole.
///
/// Same contract as `BitReader`: `peekBits` yields zeros past the end of the
/// range, but consuming bits past the end throws `.truncated`.
public struct StreamBitReader {
    public static let chunkSize = 1 << 16

    @usableFromInline let source: ByteSource
    @usableFromInline let end: UInt64
    /// Size of the range in bits.
    public let totalBits: UInt64
    /// Bits consumed so far.
    public var bitPosition: UInt64 { consumed }
    @usableFromInline var consumed: UInt64 = 0

    @usableFromInline var chunk: [UInt8] = []
    @usableFromInline var chunkIndex = 0
    @usableFromInline var nextOffset: UInt64
    /// Look-ahead bits, left-aligned; the low `64 - accumulatorCount` bits are zero.
    @usableFromInline var accumulator: UInt64 = 0
    @usableFromInline var accumulatorCount = 0

    /// Reads `count` bytes starting at `offset` in `source`.
    public init(source: ByteSource, offset: UInt64, count: UInt64) throws {
        let end = try checkedAdd(offset, count)
        guard end <= source.size else { throw RARError.truncated }
        let (bits, overflow) = count.multipliedReportingOverflow(by: 8)
        guard !overflow else { throw RARError.corruptHeader("bit length overflow") }
        self.source = source
        self.end = end
        self.totalBits = bits
        self.nextOffset = offset
    }

    @inlinable public var remainingBits: UInt64 { totalBits - consumed }

    /// Tops the accumulator up to at least 57 bits, padding with zeros past the end.
    @usableFromInline mutating func refill() throws {
        while accumulatorCount <= 56 {
            if chunkIndex == chunk.count, nextOffset < end {
                let count = Int(min(UInt64(Self.chunkSize), end - nextOffset))
                chunk = try source.read(at: nextOffset, count: count)
                chunkIndex = 0
                nextOffset += UInt64(count)
            }
            var byte: UInt8 = 0
            if chunkIndex < chunk.count {
                byte = chunk[chunkIndex]
                chunkIndex += 1
            }
            accumulator |= UInt64(byte) << UInt64(56 - accumulatorCount)
            accumulatorCount += 8
        }
    }

    /// Looks `count` (0...32) bits ahead without consuming them.
    @inlinable
    public mutating func peekBits(_ count: Int) throws -> UInt32 {
        guard count >= 0, count <= 32 else {
            throw RARError.corruptData("bit count \(count) out of range")
        }
        if count == 0 { return 0 }
        if accumulatorCount < count { try refill() }
        return UInt32(truncatingIfNeeded: accumulator >> UInt64(64 - count))
    }

    /// Consumes `count` (0...32) bits; throws `.truncated` past the end.
    @inlinable
    public mutating func skipBits(_ count: Int) throws {
        guard count >= 0, count <= 32, UInt64(count) <= remainingBits else { throw RARError.truncated }
        if accumulatorCount < count { try refill() }
        accumulator <<= UInt64(count)
        accumulatorCount -= count
        consumed += UInt64(count)
    }

    /// Reads and consumes `count` (0...32) bits.
    @inlinable
    public mutating func readBits(_ count: Int) throws -> UInt32 {
        let value = try peekBits(count)
        try skipBits(count)
        return value
    }

    /// Advances to the next byte boundary.
    public mutating func alignToByte() throws {
        try skipBits(Int((8 - consumed % 8) % 8))
    }
}
