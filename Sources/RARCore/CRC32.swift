// SPDX-License-Identifier: MIT

/// CRC-32 (IEEE 802.3, polynomial 0xEDB88320), as used by RAR and ZIP.
///
/// Incremental: `update` per block, `value` at the end.
public struct CRC32: Sendable {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
        return crc
    }

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        let table = Self.table
        var crc = state
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        state = crc
    }

    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }
}
