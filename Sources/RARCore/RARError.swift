// SPDX-License-Identifier: MIT

/// Every error that reading an archive can produce.
///
/// Any anomaly in the input ends up as one of these cases, never as a trap.
/// Callers handling untrusted input only need to catch `RARError`.
public enum RARError: Error, Equatable, Sendable {
    /// The magic bytes match no supported format.
    case unknownFormat
    /// Recognised but not (yet) supported, e.g. RAR 1.4 or an unknown RAR5 algorithm version.
    case unsupportedFormat(String)
    /// The input ends before a header or data block is complete.
    case truncated
    /// A header is internally inconsistent (field too short, invalid vint, ...).
    case corruptHeader(String)
    /// The compressed data stream is malformed (bad Huffman code, invalid table, ...).
    case corruptData(String)
    /// The header CRC does not match.
    case badHeaderCRC
    /// The CRC32 of the extracted data does not match the header.
    case badDataCRC(entry: String)
    /// The archive or an entry is encrypted.
    case encrypted
    /// The archive is (part of) a multi-volume set, or an entry spans volumes.
    case multiVolume
    /// The compression method is not supported yet (0 = store, 1...5 = levels).
    case unsupportedCompression(method: Int)
    /// An entry carries no CRC32 to verify its contents against.
    case missingChecksum(entry: String)
    /// One of the bounds in `Limits` was exceeded.
    case limitExceeded(Limits.Kind)
    /// The file name is empty after sanitising, or contains forbidden characters.
    case invalidEntryName(String)
    /// Two entries map to the same name after sanitising.
    case duplicateEntryName(String)
    /// The archive contains no extractable file.
    case emptyArchive
    /// Reading from or writing to the file system failed.
    case io(String)
}

/// Addition without an overflow trap: throws `.corruptHeader` on overflow.
@inlinable
public func checkedAdd(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let (sum, overflow) = a.addingReportingOverflow(b)
    if overflow { throw RARError.corruptHeader("offset overflow") }
    return sum
}

/// Multiplication without an overflow trap: throws `.corruptHeader` on overflow.
@inlinable
public func checkedMultiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let (product, overflow) = a.multipliedReportingOverflow(by: b)
    if overflow { throw RARError.corruptHeader("size overflow") }
    return product
}
