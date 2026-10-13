// SPDX-License-Identifier: MIT

import Foundation
import RARCore

/// A file to put into a hand-built test archive.
struct TestFile {
    var name: String
    var contents: [UInt8]
    var isDirectory = false
    /// Overrides the stored CRC (to produce a data-CRC mismatch).
    var crcOverride: UInt32?
    /// Overrides the method (0 = store); the data is still written raw.
    var method = 0
    /// RAR4 UnpVer (29 = RAR 2.9/3.x); ignored by the RAR5 builder.
    var unpackVersion: UInt8 = 29
    /// RAR5 compression information (version, solid, method, dictionary);
    /// overrides `method` in the RAR5 builder.
    var rar5Compression: UInt64?
    var encrypted = false
    var split = false
}

extension Array where Element == UInt8 {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    mutating func le64(_ v: UInt64) { for s in stride(from: 0, to: 64, by: 8) { append(UInt8((v >> UInt64(s)) & 0xFF)) } }
    mutating func vint(_ v: UInt64) {
        var value = v
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            append(byte)
        } while value != 0
    }
}

/// Builds RAR 4.x archives with stored entries, following the format spec.
enum RAR4Builder {
    struct Options {
        var mainFlags: UInt16 = 0
        var large = false
        /// Raw name bytes per file (overrides UTF-8 of `name`), e.g. "legacy\0unicode".
        var rawNames: [String: [UInt8]] = [:]
        var unicodeFlag = false
        var hostOS: UInt8 = 3
        var attributes: UInt32 = 0o100644
        var corruptHeaderCRC = false
        var includeEnd = true
        /// DOS time 2024-05-17 12:34:56.
        var dosTime: UInt32 = (UInt32(2024 - 1980) << 25) | (5 << 21) | (17 << 16) | (12 << 11) | (34 << 5) | 28
    }

    static func block(type: UInt8, flags: UInt16, body: [UInt8], corrupt: Bool = false) -> [UInt8] {
        var header: [UInt8] = []
        header.append(type)
        header.le16(flags)
        header.le16(UInt16(7 + body.count))
        header += body
        var crc = UInt16(truncatingIfNeeded: CRC32.checksum(header))
        if corrupt { crc ^= 0x5A5A }
        var out: [UInt8] = []
        out.le16(crc)
        return out + header
    }

    static func build(_ files: [TestFile], options: Options = Options()) -> [UInt8] {
        var out: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        out += block(type: 0x73, flags: options.mainFlags, body: [0, 0, 0, 0, 0, 0])
        for (index, file) in files.enumerated() {
            let nameBytes = options.rawNames[file.name] ?? Array(file.name.utf8)
            var flags: UInt16 = 0x8000
            if file.isDirectory { flags |= 0x00E0 }
            if options.large { flags |= 0x0100 }
            if options.unicodeFlag { flags |= 0x0200 }
            if file.encrypted { flags |= 0x0004 }
            if file.split { flags |= 0x0002 }
            let data = file.isDirectory ? [] : file.contents
            var body: [UInt8] = []
            body.le32(UInt32(truncatingIfNeeded: data.count))
            body.le32(UInt32(truncatingIfNeeded: data.count))
            body.append(options.hostOS)
            body.le32(file.crcOverride ?? CRC32.checksum(data))
            body.le32(options.dosTime)
            body.append(file.unpackVersion)
            body.append(UInt8(0x30 + file.method))
            body.le16(UInt16(nameBytes.count))
            body.le32(file.isDirectory ? 0o40755 | 0x10 : options.attributes)
            if options.large {
                body.le32(UInt32(UInt64(data.count) >> 32))
                body.le32(UInt32(UInt64(data.count) >> 32))
            }
            body += nameBytes
            out += block(type: 0x74, flags: flags, body: body,
                         corrupt: options.corruptHeaderCRC && index == 0)
            out += data
        }
        if options.includeEnd {
            out += block(type: 0x7B, flags: 0x4000, body: [])
        }
        return out
    }
}

/// Builds RAR 5.0 archives with stored entries, following the format spec.
enum RAR5Builder {
    struct Options {
        var archiveFlags: UInt64 = 0
        var corruptHeaderCRC = false
        var includeCRC = true
        /// Extra records appended to every file header (already encoded).
        var fileExtra: [UInt8] = []
        var unixTime: UInt32 = 1_715_949_296 // 2024-05-17 12:34:56 UTC
        var prependEncryptionHeader = false
    }

    static func header(type: UInt64, flags: UInt64, fields: [UInt8], extra: [UInt8] = [], dataSize: UInt64? = nil, corrupt: Bool = false) -> [UInt8] {
        var body: [UInt8] = []
        body.vint(type)
        var headerFlags = flags
        if !extra.isEmpty { headerFlags |= 0x01 }
        if dataSize != nil { headerFlags |= 0x02 }
        body.vint(headerFlags)
        if !extra.isEmpty { body.vint(UInt64(extra.count)) }
        if let dataSize { body.vint(dataSize) }
        body += fields
        body += extra
        var sized: [UInt8] = []
        sized.vint(UInt64(body.count))
        sized += body
        var crc = CRC32.checksum(sized)
        if corrupt { crc ^= 0xDEAD_BEEF }
        var out: [UInt8] = []
        out.le32(crc)
        return out + sized
    }

    static func build(_ files: [TestFile], options: Options = Options()) -> [UInt8] {
        var out: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        if options.prependEncryptionHeader {
            var fields: [UInt8] = []
            fields.vint(0)          // encryption version
            fields.vint(0)          // flags
            fields.append(15)       // KDF count
            fields += [UInt8](repeating: 0xAB, count: 16) // salt
            out += header(type: 4, flags: 0, fields: fields)
        }
        var mainFields: [UInt8] = []
        mainFields.vint(options.archiveFlags)
        out += header(type: 1, flags: 0, fields: mainFields)

        for (index, file) in files.enumerated() {
            let data = file.isDirectory ? [] : file.contents
            var fields: [UInt8] = []
            var fileFlags: UInt64 = 0x02
            if file.isDirectory { fileFlags |= 0x01 }
            if options.includeCRC && !file.isDirectory { fileFlags |= 0x04 }
            fields.vint(fileFlags)
            fields.vint(UInt64(data.count))
            fields.vint(file.isDirectory ? 0o40755 : 0o100644)
            fields.le32(options.unixTime)
            if options.includeCRC && !file.isDirectory {
                fields.le32(file.crcOverride ?? CRC32.checksum(data))
            }
            fields.vint(file.rar5Compression ?? UInt64(file.method) << 7) // default: version 0, 128 KiB
            fields.vint(1)                          // host OS: Unix
            let nameBytes = Array(file.name.utf8)
            fields.vint(UInt64(nameBytes.count))
            fields += nameBytes

            var extra = options.fileExtra
            if file.encrypted {
                var record: [UInt8] = []
                record.vint(0x01)                   // type: encryption
                record += [0, 0, 15] + [UInt8](repeating: 1, count: 32)
                var sized: [UInt8] = []
                sized.vint(UInt64(record.count))
                extra += sized + record
            }
            let flags: UInt64 = file.split ? 0x10 : 0
            out += header(type: 2, flags: flags, fields: fields, extra: extra,
                          dataSize: UInt64(data.count),
                          corrupt: options.corruptHeaderCRC && index == 0)
            out += data
        }
        var endFields: [UInt8] = []
        endFields.vint(0)
        out += header(type: 5, flags: 0, fields: endFields)
        return out
    }
}

/// Deterministic pseudo-random bytes (xorshift), so failures reproduce.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

func randomBytes(_ count: Int, seed: UInt64) -> [UInt8] {
    var generator = SeededGenerator(seed: seed)
    return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
}

/// The standard set of files used across tests.
func sampleFiles() -> [TestFile] {
    [
        TestFile(name: "comic/page01.jpg", contents: randomBytes(70_000, seed: 1)),
        TestFile(name: "comic/page02.png", contents: randomBytes(1_234, seed: 2)),
        TestFile(name: "comic", contents: [], isDirectory: true),
        TestFile(name: "comic/empty.txt", contents: []),
        TestFile(name: "comic/één – ünïcode.txt", contents: Array("hallo wereld\n".utf8)),
    ]
}
