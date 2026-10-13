// SPDX-License-Identifier: MIT

/// Reads little-endian fields from a header buffer with bounds checking.
///
/// Every read checks up front that enough bytes remain; a shortfall throws
/// `.truncated` (or `.corruptHeader` when the buffer itself was complete).
public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var position: Int
    /// Error thrown when a field runs past the end.
    private let shortReadError: RARError

    public init(_ bytes: [UInt8], position: Int = 0, shortReadError: RARError = .truncated) {
        self.bytes = bytes
        self.position = min(max(0, position), bytes.count)
        self.shortReadError = shortReadError
    }

    public var remaining: Int { bytes.count - position }
    public var isAtEnd: Bool { position >= bytes.count }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw shortReadError }
        let slice = bytes[position..<(position + count)]
        position += count
        return slice
    }

    public mutating func readU8() throws -> UInt8 {
        let s = try take(1)
        return s[s.startIndex]
    }

    public mutating func readU16() throws -> UInt16 {
        let s = try take(2)
        return UInt16(s[s.startIndex]) | UInt16(s[s.startIndex + 1]) << 8
    }

    public mutating func readU32() throws -> UInt32 {
        let s = try take(4)
        var value: UInt32 = 0
        for (i, byte) in s.enumerated() {
            value |= UInt32(byte) << (8 * UInt32(i))
        }
        return value
    }

    public mutating func readU64() throws -> UInt64 {
        let s = try take(8)
        var value: UInt64 = 0
        for (i, byte) in s.enumerated() {
            value |= UInt64(byte) << (8 * UInt64(i))
        }
        return value
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        Array(try take(count))
    }

    public mutating func skip(_ count: Int) throws {
        _ = try take(count)
    }

    /// Moves to an absolute position inside the buffer.
    public mutating func seek(to newPosition: Int) throws {
        guard newPosition >= 0, newPosition <= bytes.count else { throw shortReadError }
        position = newPosition
    }

    /// RAR5 variable-length integer: 7 bits per byte, least significant first,
    /// high bit = continuation. At most 10 bytes; bits above 64 are an error.
    public mutating func readVInt() throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<10 {
            let byte = try readU8()
            let payload = UInt64(byte & 0x7F)
            if index == 9 && payload > 1 {
                throw RARError.corruptHeader("vint overflow")
            }
            value |= payload << (7 * UInt64(index))
            if byte & 0x80 == 0 { return value }
        }
        throw RARError.corruptHeader("vint too long")
    }

    /// Reads a vint and converts it to `Int`, with a range check.
    public mutating func readVIntAsInt() throws -> Int {
        let value = try readVInt()
        guard value <= UInt64(Int.max) else { throw RARError.corruptHeader("vint too large") }
        return Int(value)
    }
}
