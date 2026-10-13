// SPDX-License-Identifier: MIT

/// Reads bits MSB-first from a buffer, the way the RAR decoders do.
///
/// `peekBits` yields zeros past the end (decoders often look ahead), but any
/// step that actually consumes bits past the end throws `.truncated`. A
/// decoder can therefore never read outside the buffer.
public struct BitReader {
    public let bytes: [UInt8]
    /// Position in bits from the start of `bytes`.
    public private(set) var bitPosition: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.bitPosition = 0
    }

    public var totalBits: Int { bytes.count * 8 }
    public var remainingBits: Int { max(0, totalBits - bitPosition) }

    /// Looks `count` (0...32) bits ahead without consuming them.
    public func peekBits(_ count: Int) throws -> UInt32 {
        guard count >= 0, count <= 32 else {
            throw RARError.corruptHeader("bit count \(count) out of range")
        }
        var value: UInt64 = 0
        var bit = bitPosition
        var gathered = 0
        while gathered < count {
            let byteIndex = bit >> 3
            let byte: UInt8 = byteIndex < bytes.count ? bytes[byteIndex] : 0
            let offsetInByte = bit & 7
            let available = 8 - offsetInByte
            let take = min(available, count - gathered)
            let shifted = (UInt64(byte) << UInt64(offsetInByte)) & 0xFF
            let chunk = shifted >> UInt64(8 - take)
            value = (value << UInt64(take)) | chunk
            gathered += take
            bit += take
        }
        return UInt32(truncatingIfNeeded: value)
    }

    /// Consumes `count` bits; throws `.truncated` if that goes past the end.
    public mutating func skipBits(_ count: Int) throws {
        guard count >= 0, count <= remainingBits else { throw RARError.truncated }
        bitPosition += count
    }

    /// Reads and consumes `count` (0...32) bits.
    public mutating func readBits(_ count: Int) throws -> UInt32 {
        let value = try peekBits(count)
        try skipBits(count)
        return value
    }

    public mutating func readBit() throws -> UInt32 {
        try readBits(1)
    }

    /// Advances to the next byte boundary.
    public mutating func alignToByte() throws {
        let pad = (8 - (bitPosition & 7)) & 7
        try skipBits(pad)
    }
}
