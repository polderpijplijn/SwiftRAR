// SPDX-License-Identifier: MIT

import Foundation

/// Header parser for the RAR 1.5-4.x archive format ("RAR4").
///
/// Original implementation from the published format description. Walks the
/// block chain from just after the signature; every block is read as one
/// bounded buffer (a RAR4 header is at most 64 KiB) and every offset is
/// validated against the source size before it is followed.
enum RAR4Parser {
    // Block types.
    static let typeMark: UInt8 = 0x72
    static let typeMain: UInt8 = 0x73
    static let typeFile: UInt8 = 0x74
    static let typeOldComment: UInt8 = 0x75
    static let typeOldAV: UInt8 = 0x76
    static let typeOldService: UInt8 = 0x77
    static let typeProtect: UInt8 = 0x78
    static let typeSign: UInt8 = 0x79
    static let typeService: UInt8 = 0x7A
    static let typeEnd: UInt8 = 0x7B

    // Main header flags.
    static let mainVolume: UInt16 = 0x0001
    static let mainSolid: UInt16 = 0x0008
    static let mainPassword: UInt16 = 0x0080

    // File header flags.
    static let fileSplitBefore: UInt16 = 0x0001
    static let fileSplitAfter: UInt16 = 0x0002
    static let filePassword: UInt16 = 0x0004
    static let fileSolid: UInt16 = 0x0010
    static let fileWindowMask: UInt16 = 0x00E0
    static let fileDirectory: UInt16 = 0x00E0
    static let fileLarge: UInt16 = 0x0100
    static let fileUnicode: UInt16 = 0x0200
    static let longBlock: UInt16 = 0x8000

    static let baseHeaderSize = 7
    static let fileHeaderFixedSize = 32

    static let hostUnix: UInt8 = 3

    static func parse(_ source: ByteSource, limits: Limits) throws -> (entries: [RAREntry], isSolid: Bool) {
        var position = UInt64(ArchiveFormat.rar4Magic.count)
        var entries: [RAREntry] = []
        var fileHeaderCount = 0
        var isSolid = false
        var sawMain = false

        while position < source.size {
            let remaining = source.size - position
            guard remaining >= UInt64(baseHeaderSize) else { throw RARError.truncated }

            var base = ByteReader(try source.read(at: position, count: baseHeaderSize))
            let storedCRC = try base.readU16()
            let type = try base.readU8()
            let flags = try base.readU16()
            let headSize = Int(try base.readU16())
            guard headSize >= baseHeaderSize else {
                throw RARError.corruptHeader("block header size \(headSize) too small")
            }

            let header = try source.read(at: position, count: headSize)
            var reader = ByteReader(header, position: baseHeaderSize, shortReadError: .corruptHeader("block field beyond header size"))
            var dataSize: UInt64 = 0

            switch type {
            case typeMain:
                try verifyCRC(header, stored: storedCRC)
                guard headSize >= 13 else { throw RARError.corruptHeader("main header too small") }
                if flags & mainPassword != 0 { throw RARError.encrypted }
                if flags & mainVolume != 0 { throw RARError.multiVolume }
                isSolid = flags & mainSolid != 0
                sawMain = true

            case typeFile, typeService:
                try verifyCRC(header, stored: storedCRC)
                guard headSize >= fileHeaderFixedSize else {
                    throw RARError.corruptHeader("file header too small")
                }
                let parsed = try parseFileHeader(
                    &reader, flags: flags, dataOffset: try checkedAdd(position, UInt64(headSize))
                )
                dataSize = parsed.packedSize
                if type == typeFile {
                    guard sawMain else { throw RARError.corruptHeader("file header before main header") }
                    fileHeaderCount += 1
                    if fileHeaderCount > limits.maxEntries { throw RARError.limitExceeded(.entries) }
                    entries.append(parsed)
                }
                // Service headers (comments, recovery record, NTFS streams, ...) are skipped.

            case typeEnd:
                try verifyCRC(header, stored: storedCRC)
                return (entries, isSolid)

            default:
                // Legacy blocks. Old AV, old service and sign blocks were never
                // CRC-protected consistently, so like unrar we do not check them.
                if type != typeOldAV && type != typeOldService && type != typeSign && type != typeMark {
                    try verifyCRC(header, stored: storedCRC)
                }
                if flags & longBlock != 0 {
                    dataSize = UInt64(try reader.readU32())
                }
            }

            let next = try checkedAdd(try checkedAdd(position, UInt64(headSize)), dataSize)
            guard next <= source.size else { throw RARError.truncated }
            position = next
        }

        // No end-of-archive block: tolerated (older RAR versions omit it).
        guard sawMain else { throw RARError.corruptHeader("missing main header") }
        return (entries, isSolid)
    }

    /// RAR4 header CRC: the low 16 bits of CRC32 over the header from byte 2.
    static func verifyCRC(_ header: [UInt8], stored: UInt16) throws {
        let crc = CRC32.checksum(header[2...])
        if UInt16(truncatingIfNeeded: crc) != stored { throw RARError.badHeaderCRC }
    }

    static func parseFileHeader(_ reader: inout ByteReader, flags: UInt16, dataOffset: UInt64) throws -> RAREntry {
        let lowPacked = try reader.readU32()
        let lowUnpacked = try reader.readU32()
        let hostOS = try reader.readU8()
        let fileCRC = try reader.readU32()
        let dosTime = try reader.readU32()
        let unpackVersion = try reader.readU8()
        let methodByte = try reader.readU8()
        let nameSize = Int(try reader.readU16())
        let attributes = try reader.readU32()

        var packedSize = UInt64(lowPacked)
        var unpackedSize = UInt64(lowUnpacked)
        if flags & fileLarge != 0 {
            packedSize |= UInt64(try reader.readU32()) << 32
            unpackedSize |= UInt64(try reader.readU32()) << 32
        }
        let nameBytes = try reader.readBytes(nameSize)
        // Salt, extended time and other trailing fields are covered by HEAD_SIZE
        // and need no parsing: the data always starts at block + HEAD_SIZE.

        guard (0x30...0x35).contains(methodByte) else {
            throw RARError.corruptHeader("unknown method byte \(methodByte)")
        }

        var isDirectory = flags & fileWindowMask == fileDirectory
        if unpackVersion < 20 && attributes & 0x10 != 0 { isDirectory = true }

        // Unix symlinks store the link target as file data; never extract them.
        let isUnixLink = hostOS == hostUnix && attributes & 0xF000 == 0xA000

        let windowBits = UInt64((flags & fileWindowMask) >> 5)
        let dictionarySize: UInt64 = isDirectory ? 0 : UInt64(0x10000) << windowBits

        return RAREntry(
            rawName: decodeName(nameBytes),
            packedSize: packedSize,
            unpackedSize: unpackedSize,
            crc32: fileCRC,
            method: Int(methodByte - 0x30),
            unpackVersion: Int(unpackVersion),
            dictionarySize: dictionarySize,
            isDirectory: isDirectory,
            isEncrypted: flags & filePassword != 0,
            isSplit: flags & (fileSplitBefore | fileSplitAfter) != 0,
            isSolid: flags & fileSolid != 0,
            isLink: isUnixLink,
            modified: DOSTime.date(fromPacked: dosTime),
            dataOffset: dataOffset
        )
    }

    /// Decodes a RAR4 name field.
    ///
    /// With the Unicode flag the field holds either plain UTF-8, or a legacy
    /// name, a zero byte and RAR's compressed Unicode encoding. Phase 1 uses the
    /// part before the zero byte; decoding the compressed form is a port of
    /// unrar's encname and belongs in RARDecode (see roadmap).
    static func decodeName(_ bytes: [UInt8]) -> String {
        var nameBytes = bytes
        if let zero = bytes.firstIndex(of: 0) {
            nameBytes = Array(bytes[..<zero])
        }
        if let utf8 = String(bytes: nameBytes, encoding: .utf8) {
            return utf8
        }
        // Not UTF-8: an OEM/ANSI code page. Latin-1 maps every byte, so the
        // name never fails to decode; it may look wrong but stays harmless.
        return String(decoding: nameBytes.map { UInt16($0) }, as: UTF16.self)
    }
}
