// SPDX-License-Identifier: MIT

import Foundation

/// Header parser for the RAR 5.0 archive format ("RAR5").
///
/// Original implementation from the published format description. Every
/// header is `CRC32 | size vint | type vint | flags vint | ...`, where the
/// size vint is at most 3 bytes (headers are at most 2 MiB).
enum RAR5Parser {
    // Header types.
    static let typeMain: UInt64 = 1
    static let typeFile: UInt64 = 2
    static let typeService: UInt64 = 3
    static let typeEncryption: UInt64 = 4
    static let typeEnd: UInt64 = 5

    // Common header flags.
    static let flagExtra: UInt64 = 0x0001
    static let flagData: UInt64 = 0x0002
    static let flagSplitBefore: UInt64 = 0x0008
    static let flagSplitAfter: UInt64 = 0x0010

    // Main header flags.
    static let mainVolume: UInt64 = 0x0001
    static let mainVolumeNumber: UInt64 = 0x0002
    static let mainSolid: UInt64 = 0x0004

    // File header flags.
    static let fileDirectory: UInt64 = 0x0001
    static let fileUnixTime: UInt64 = 0x0002
    static let fileCRC32: UInt64 = 0x0004
    static let fileUnknownSize: UInt64 = 0x0008

    // File extra record types.
    static let extraEncryption: UInt64 = 0x01
    static let extraTime: UInt64 = 0x03
    static let extraRedirection: UInt64 = 0x05

    // Compression information.
    static let compressionRAR5Compat: UInt64 = 0x10_0000

    static let maxHeaderSize: UInt64 = 2 << 20
    static let maxSizeVIntBytes = 3

    static func parse(_ source: ByteSource, limits: Limits) throws -> (entries: [RAREntry], isSolid: Bool) {
        var position = UInt64(ArchiveFormat.rar5Magic.count)
        var entries: [RAREntry] = []
        var fileHeaderCount = 0
        var isSolid = false
        var sawMain = false
        var headerBytes: UInt64 = 0

        while position < source.size {
            if Task.isCancelled { throw RARError.cancelled }
            let header = try readHeader(source, at: position, remainingBudget: limits.maxHeaderBytes - headerBytes)
            headerBytes += UInt64(header.bytes.count)
            var reader = ByteReader(header.bytes, position: header.bodyStart,
                                    shortReadError: .corruptHeader("field beyond header size"))

            let type = try reader.readVInt()
            let flags = try reader.readVInt()
            var extraSize: UInt64 = 0
            var dataSize: UInt64 = 0
            if flags & flagExtra != 0 { extraSize = try reader.readVInt() }
            if flags & flagData != 0 { dataSize = try reader.readVInt() }

            // The extra area sits at the very end of the header.
            guard extraSize <= UInt64(header.bytes.count - reader.position) else {
                throw RARError.corruptHeader("extra area larger than header")
            }
            let extraStart = header.bytes.count - Int(extraSize)
            let dataOffset = try checkedAdd(position, UInt64(header.bytes.count))

            switch type {
            case typeMain:
                let archiveFlags = try reader.readVInt()
                if archiveFlags & mainVolume != 0 { throw RARError.multiVolume }
                if archiveFlags & mainVolumeNumber != 0 { _ = try reader.readVInt() }
                isSolid = archiveFlags & mainSolid != 0
                sawMain = true

            case typeEncryption:
                throw RARError.encrypted

            case typeFile, typeService:
                var entry = try parseFileHeader(&reader, extraStart: extraStart, dataOffset: dataOffset,
                                                maxNameLength: limits.maxNameLength)
                entry.packedSize = dataSize
                entry.isSplit = flags & (flagSplitBefore | flagSplitAfter) != 0
                if type == typeFile {
                    guard sawMain else { throw RARError.corruptHeader("file header before main header") }
                    fileHeaderCount += 1
                    if fileHeaderCount > limits.maxEntries { throw RARError.limitExceeded(.entries) }
                    entries.append(entry)
                }
                // Service headers (CMT, QO, ACL, STM, RR) are skipped.

            case typeEnd:
                return (entries, isSolid)

            default:
                // Unknown header types are skipped, as the format prescribes.
                break
            }

            let next = try checkedAdd(dataOffset, dataSize)
            guard next <= source.size else { throw RARError.truncated }
            position = next
        }

        guard sawMain else { throw RARError.corruptHeader("missing main header") }
        return (entries, isSolid)
    }

    /// Reads one complete header and verifies its CRC32.
    /// `bodyStart` is the offset of the type field inside `bytes`.
    static func readHeader(
        _ source: ByteSource, at position: UInt64, remainingBudget: UInt64
    ) throws -> (bytes: [UInt8], bodyStart: Int) {
        let available = source.size - position
        // Read enough for a full 10-byte vint so an over-long size is reported
        // as corrupt rather than truncated.
        let prefixLength = Int(min(available, 14))
        guard prefixLength >= 5 else { throw RARError.truncated }

        var prefix = ByteReader(try source.read(at: position, count: prefixLength))
        let storedCRC = try prefix.readU32()
        let sizeStart = prefix.position
        let headerSize = try prefix.readVInt()
        let sizeBytes = prefix.position - sizeStart
        guard sizeBytes <= maxSizeVIntBytes else { throw RARError.corruptHeader("header size vint too long") }
        guard headerSize > 0, headerSize <= maxHeaderSize else {
            throw RARError.corruptHeader("header size \(headerSize) out of range")
        }

        let total = 4 + sizeBytes + Int(headerSize)
        // Only the fixed-size prefix above is needed to reject a header
        // that exceeds the archive's remaining metadata budget.
        guard UInt64(total) <= remainingBudget else { throw RARError.limitExceeded(.headerBytes) }
        let bytes = try source.read(at: position, count: total)
        if CRC32.checksum(bytes[4...]) != storedCRC { throw RARError.badHeaderCRC }
        return (bytes, 4 + sizeBytes)
    }

    static func parseFileHeader(
        _ reader: inout ByteReader, extraStart: Int, dataOffset: UInt64, maxNameLength: Int
    ) throws -> RAREntry {
        let fileFlags = try reader.readVInt()
        let unpackedSize = try reader.readVInt()
        _ = try reader.readVInt() // attributes
        var modified: Date?
        if fileFlags & fileUnixTime != 0 {
            modified = Date(timeIntervalSince1970: TimeInterval(try reader.readU32()))
        }
        var crc: UInt32?
        if fileFlags & fileCRC32 != 0 { crc = try reader.readU32() }
        let compression = try reader.readVInt()
        _ = try reader.readVInt() // host OS
        let nameLength = try reader.readVIntAsInt()
        guard nameLength <= maxNameLength else { throw RARError.limitExceeded(.nameLength) }
        let nameBytes = try reader.readBytes(nameLength)
        guard reader.position <= extraStart else {
            throw RARError.corruptHeader("file fields overlap extra area")
        }
        guard let name = String(bytes: nameBytes, encoding: .utf8) else {
            throw RARError.invalidEntryName(String(decoding: nameBytes, as: UTF8.self))
        }

        let algorithmVersion = Int(compression & 0x3F)
        let method = Int((compression >> 7) & 0x07)
        // Version 0 has 4 dictionary bits (128 KiB to 4 GiB), version 1 has 5.
        var dictionarySize: UInt64
        let unpackVersion: Int
        switch algorithmVersion {
        case 0:
            dictionarySize = UInt64(0x20000) << ((compression >> 10) & 0x0F)
            unpackVersion = RAREntry.unpackVersionRAR5
        case 1:
            // RAR7: fraction in 1/32 of the base size. The compat flag says
            // the data uses the RAR5 algorithm despite the RAR7 dictionary.
            dictionarySize = UInt64(0x20000) << ((compression >> 10) & 0x1F)
            dictionarySize += dictionarySize / 32 * ((compression >> 15) & 0x1F)
            unpackVersion = compression & compressionRAR5Compat != 0 ? RAREntry.unpackVersionRAR5 : RAREntry.unpackVersionRAR7
        default:
            throw RARError.unsupportedFormat("RAR5 algorithm version \(algorithmVersion)")
        }
        if fileFlags & fileUnknownSize != 0 {
            throw RARError.unsupportedFormat("unknown unpacked size")
        }

        var isEncrypted = false
        var isLink = false
        reader = ByteReader(reader.bytes, position: extraStart,
                            shortReadError: .corruptHeader("extra record beyond header"))
        while !reader.isAtEnd {
            let recordSize = try reader.readVIntAsInt()
            let recordStart = reader.position
            guard recordSize > 0, recordSize <= reader.remaining else {
                throw RARError.corruptHeader("extra record size \(recordSize) out of range")
            }
            let recordEnd = recordStart + recordSize
            let recordType = try reader.readVInt()
            switch recordType {
            case extraEncryption:
                isEncrypted = true
            case extraRedirection:
                isLink = true
            case extraTime where modified == nil:
                modified = try parseTimeRecord(&reader, end: recordEnd)
            default:
                break
            }
            try reader.seek(to: recordEnd)
        }

        return RAREntry(
            rawName: name,
            packedSize: 0, // filled in from the header's data size
            unpackedSize: unpackedSize,
            crc32: crc,
            method: method,
            unpackVersion: unpackVersion,
            dictionarySize: dictionarySize,
            isDirectory: fileFlags & fileDirectory != 0,
            isEncrypted: isEncrypted,
            isSplit: false, // filled in from the header flags
            isSolid: compression & 0x40 != 0,
            isLink: isLink,
            modified: modified,
            dataOffset: dataOffset
        )
    }

    /// High-precision time record: flags, then mtime as Unix seconds (u32) or
    /// Windows FILETIME (u64, 100 ns since 1601). Optional nanoseconds follow
    /// all times and are irrelevant at DOS-time resolution.
    static func parseTimeRecord(_ reader: inout ByteReader, end: Int) throws -> Date? {
        let flags = try reader.readVInt()
        let unixFormat = flags & 0x01 != 0
        let hasMTime = flags & 0x02 != 0
        guard hasMTime, reader.position < end else { return nil }
        if unixFormat {
            let seconds = try reader.readU32()
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        let fileTime = try reader.readU64()
        let secondsSince1601 = fileTime / 10_000_000
        let unixEpochIn1601: UInt64 = 11_644_473_600
        guard secondsSince1601 >= unixEpochIn1601 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(secondsSince1601 - unixEpochIn1601))
    }
}
