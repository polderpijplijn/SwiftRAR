// SPDX-License-Identifier: MIT

import XCTest
@testable import RARCore
@testable import SwiftRAR

/// Shared expectations for the RAR4 and RAR5 parsers.
class ArchiveTestCase: XCTestCase {
    func build(_ files: [TestFile]) -> [UInt8] { fatalError("override") }

    func convert(_ bytes: [UInt8], limits: Limits = .default) throws -> (ConversionResult, [UInt8]) {
        let output = MemoryOutput()
        let result = try convertToCBZ(source: DataSource(bytes), output: output, limits: limits)
        return (result, output.bytes)
    }

    func assertConversionThrows(_ bytes: [UInt8], _ expected: RARError, limits: Limits = .default,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try convert(bytes, limits: limits), file: file, line: line) {
            XCTAssertEqual($0 as? RARError, expected, file: file, line: line)
        }
    }
}

final class RAR4Tests: ArchiveTestCase {
    override func build(_ files: [TestFile]) -> [UInt8] { RAR4Builder.build(files) }

    func testParsesStoredEntries() throws {
        let archive = try RARArchive(source: DataSource(build(sampleFiles())), limits: .default)
        XCTAssertEqual(archive.format, .rar4)
        XCTAssertEqual(archive.entries.map(\.rawName), sampleFiles().map(\.name))
        let page = archive.entries[0]
        XCTAssertEqual(page.unpackedSize, 70_000)
        XCTAssertEqual(page.packedSize, 70_000)
        XCTAssertEqual(page.method, 0)
        XCTAssertEqual(page.crc32, CRC32.checksum(sampleFiles()[0].contents))
        XCTAssertTrue(archive.entries[2].isDirectory)
        XCTAssertNotNil(page.modified)
    }

    func testConversionSkipsDirectories() throws {
        let (result, zip) = try convert(build(sampleFiles()))
        XCTAssertEqual(result.sourceFormat, .rar4)
        XCTAssertEqual(result.entryCount, 4)
        XCTAssertEqual(result.totalBytes, 70_000 + 1_234 + 13)
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
    }

    func testLargeFlagAndUnicodeNameBeforeZero() throws {
        var options = RAR4Builder.Options()
        options.large = true
        options.unicodeFlag = true
        options.rawNames = ["page.jpg": Array("page.jpg".utf8) + [0x00, 0x12, 0x34, 0x56]]
        let bytes = RAR4Builder.build([TestFile(name: "page.jpg", contents: [1, 2, 3])], options: options)
        let archive = try RARArchive(source: DataSource(bytes), limits: .default)
        XCTAssertEqual(archive.entries.first?.rawName, "page.jpg")
        XCTAssertEqual(archive.entries.first?.unpackedSize, 3)
    }

    func testNonUTF8LegacyNameDecodesAsLatin1() throws {
        var options = RAR4Builder.Options()
        options.rawNames = ["x": [0x63, 0x61, 0x66, 0xE9]] // "café" in Latin-1
        let bytes = RAR4Builder.build([TestFile(name: "x", contents: [1])], options: options)
        let archive = try RARArchive(source: DataSource(bytes), limits: .default)
        XCTAssertEqual(archive.entries.first?.rawName, "café")
    }

    func testMissingEndBlockIsTolerated() throws {
        var options = RAR4Builder.Options()
        options.includeEnd = false
        let bytes = RAR4Builder.build(sampleFiles(), options: options)
        XCTAssertEqual(try convert(bytes).0.entryCount, 4)
    }

    func testBadHeaderCRC() {
        var options = RAR4Builder.Options()
        options.corruptHeaderCRC = true
        assertConversionThrows(RAR4Builder.build(sampleFiles(), options: options), .badHeaderCRC)
    }

    func testBadDataCRC() {
        let files = [TestFile(name: "a.jpg", contents: [1, 2, 3], crcOverride: 0x1234_5678)]
        assertConversionThrows(build(files), .badDataCRC(entry: "a.jpg"))
    }

    func testEncryptedArchiveAndEntry() {
        var options = RAR4Builder.Options()
        options.mainFlags = 0x0080
        assertConversionThrows(RAR4Builder.build(sampleFiles(), options: options), .encrypted)
        assertConversionThrows(build([TestFile(name: "a", contents: [1], encrypted: true)]), .encrypted)
    }

    func testMultiVolume() {
        var options = RAR4Builder.Options()
        options.mainFlags = 0x0001
        assertConversionThrows(RAR4Builder.build(sampleFiles(), options: options), .multiVolume)
        assertConversionThrows(build([TestFile(name: "a", contents: [1], split: true)]), .multiVolume)
    }

    func testCompressedEntryWithOtherUnpackVersionIsUnsupported() {
        for version: UInt8 in [15, 20, 26, 36] {
            assertConversionThrows(build([TestFile(name: "a", contents: [1, 2], method: 3, unpackVersion: version)]),
                                   .unsupportedCompression(method: 3))
        }
    }

    func testGarbageV29DataIsRejected() {
        // Two raw bytes are no valid unpack29 stream: the table header runs off the end.
        assertConversionThrows(build([TestFile(name: "a", contents: [1, 2], method: 3)]), .truncated)
    }

    func testUnixSymlinkIsSkipped() throws {
        var options = RAR4Builder.Options()
        options.attributes = 0o120777
        let link = RAR4Builder.build([TestFile(name: "link", contents: Array("/etc/passwd".utf8))], options: options)
        assertConversionThrows(link, .emptyArchive)
    }

    func testTraversalNamesAreSanitised() throws {
        let files = [TestFile(name: "..\\..\\evil.jpg", contents: [1]), TestFile(name: "../../good.jpg", contents: [2])]
        let archive = try RARArchive(source: DataSource(build(files)), limits: .default)
        let plan = try planExtraction(archive, limits: .default)
        XCTAssertEqual(plan.map(\.1), ["evil.jpg", "good.jpg"])
    }

    func testDuplicateNamesAfterSanitising() {
        let files = [TestFile(name: "a/b.jpg", contents: [1]), TestFile(name: "a\\b.jpg", contents: [2])]
        assertConversionThrows(build(files), .duplicateEntryName("a/b.jpg"))
    }

    func testLimits() {
        let bytes = build(sampleFiles())
        var limits = Limits.default
        limits.maxEntries = 4
        assertConversionThrows(bytes, .limitExceeded(.entries), limits: limits)
        limits = .default
        limits.maxEntrySize = 69_999
        assertConversionThrows(bytes, .limitExceeded(.entrySize), limits: limits)
        limits = .default
        limits.maxTotalSize = 70_500
        assertConversionThrows(bytes, .limitExceeded(.totalSize), limits: limits)
        limits = .default
        limits.maxNameLength = 10
        assertConversionThrows(bytes, .limitExceeded(.nameLength), limits: limits)
    }

    func testAbsurdSizesAreRejected() {
        // Claim 4 GiB of data in a tiny archive (LHD_LARGE with a huge high word).
        var bytes = build([TestFile(name: "a", contents: [1, 2, 3])])
        // Patch packed size (offset 7 of the file block) and fix the header CRC.
        let fileBlock = 7 + 13
        bytes[fileBlock + 7] = 0xFF
        bytes[fileBlock + 8] = 0xFF
        bytes[fileBlock + 9] = 0xFF
        bytes[fileBlock + 10] = 0x7F
        let headSize = Int(bytes[fileBlock + 5]) | Int(bytes[fileBlock + 6]) << 8
        let crc = UInt16(truncatingIfNeeded: CRC32.checksum(bytes[(fileBlock + 2)..<(fileBlock + headSize)]))
        bytes[fileBlock] = UInt8(crc & 0xFF)
        bytes[fileBlock + 1] = UInt8(crc >> 8)
        assertConversionThrows(bytes, .truncated)
    }

    func testHeaderSizeSmallerThanBlockIsRejected() {
        var bytes = build(sampleFiles())
        bytes[7 + 5] = 3 // main header HEAD_SIZE = 3
        bytes[7 + 6] = 0
        assertConversionThrows(bytes, .corruptHeader("block header size 3 too small"))
    }
}

final class RAR5Tests: ArchiveTestCase {
    override func build(_ files: [TestFile]) -> [UInt8] { RAR5Builder.build(files) }

    func testParsesStoredEntries() throws {
        let archive = try RARArchive(source: DataSource(build(sampleFiles())), limits: .default)
        XCTAssertEqual(archive.format, .rar5)
        XCTAssertEqual(archive.entries.map(\.rawName), sampleFiles().map(\.name))
        XCTAssertEqual(archive.entries[0].unpackedSize, 70_000)
        XCTAssertEqual(archive.entries[0].dictionarySize, 128 << 10)
        XCTAssertEqual(archive.entries[0].modified, Date(timeIntervalSince1970: 1_715_949_296))
        XCTAssertTrue(archive.entries[2].isDirectory)
    }

    func testConversion() throws {
        let (result, _) = try convert(build(sampleFiles()))
        XCTAssertEqual(result.sourceFormat, .rar5)
        XCTAssertEqual(result.entryCount, 4)
    }

    func testBadHeaderCRC() {
        var options = RAR5Builder.Options()
        options.corruptHeaderCRC = true
        assertConversionThrows(RAR5Builder.build(sampleFiles(), options: options), .badHeaderCRC)
    }

    func testBadDataCRC() {
        assertConversionThrows(build([TestFile(name: "a", contents: [9], crcOverride: 1)]), .badDataCRC(entry: "a"))
    }

    func testMissingCRCIsRejected() {
        var options = RAR5Builder.Options()
        options.includeCRC = false
        assertConversionThrows(RAR5Builder.build([TestFile(name: "a", contents: [1])], options: options),
                               .missingChecksum(entry: "a"))
    }

    func testEncryptionHeaderAndRecord() {
        var options = RAR5Builder.Options()
        options.prependEncryptionHeader = true
        assertConversionThrows(RAR5Builder.build(sampleFiles(), options: options), .encrypted)
        assertConversionThrows(build([TestFile(name: "a", contents: [1], encrypted: true)]), .encrypted)
    }

    func testMultiVolume() {
        var options = RAR5Builder.Options()
        options.archiveFlags = 0x0001
        assertConversionThrows(RAR5Builder.build(sampleFiles(), options: options), .multiVolume)
        assertConversionThrows(build([TestFile(name: "a", contents: [1], split: true)]), .multiVolume)
    }

    func testGarbageCompressedDataIsRejected() {
        // One raw byte is no valid unpack50 stream: the block header runs off the end.
        assertConversionThrows(build([TestFile(name: "a", contents: [1], method: 5)]), .truncated)
    }

    func testRedirectionRecordIsSkipped() {
        var record: [UInt8] = []
        record.vint(0x05) // redirection
        record.vint(0x01) // unix symlink
        record.vint(0)    // flags
        record.vint(4)
        record += Array("/etc".utf8)
        var extra: [UInt8] = []
        extra.vint(UInt64(record.count))
        extra += record
        var options = RAR5Builder.Options()
        options.fileExtra = extra
        assertConversionThrows(RAR5Builder.build([TestFile(name: "link", contents: [])], options: options), .emptyArchive)
    }

    func testOversizedExtraRecordIsRejected() {
        var extra: [UInt8] = []
        extra.vint(200) // record claims 200 bytes, header has only a few
        extra.vint(0x07)
        var options = RAR5Builder.Options()
        options.fileExtra = extra
        assertConversionThrows(RAR5Builder.build([TestFile(name: "a", contents: [1])], options: options),
                               .corruptHeader("extra record size 200 out of range"))
    }

    func testHugeDataSizeIsTruncated() {
        var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        bytes += RAR5Builder.header(type: 1, flags: 0, fields: [0])
        var fields: [UInt8] = []
        fields.vint(0x04); fields.vint(1 << 40); fields.vint(0); fields.le32(0)
        fields.vint(0); fields.vint(1); fields.vint(1); fields += [0x61]
        bytes += RAR5Builder.header(type: 2, flags: 0, fields: fields, dataSize: 1 << 40)
        assertConversionThrows(bytes, .truncated)
    }

    func testHeaderSizeOutOfRange() {
        var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        bytes += [0, 0, 0, 0, 0xFF, 0xFF, 0x7F] // 3-byte vint = 2 MiB - 1 ... still > available
        assertConversionThrows(bytes, .truncated)
        var tooBig: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        tooBig += [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x01] // 4-byte vint
        assertConversionThrows(tooBig, .corruptHeader("header size vint too long"))
        var zero: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        zero += [0, 0, 0, 0, 0x00, 0, 0]
        assertConversionThrows(zero, .corruptHeader("header size 0 out of range"))
    }

    func testDictionaryLimitIgnoredForStoredEntries() throws {
        var limits = Limits.default
        limits.maxDictionarySize = 64 << 10
        // The header asks for 128 KiB, but store needs no dictionary.
        XCTAssertNoThrow(try convert(build([TestFile(name: "a", contents: [1])]), limits: limits))
    }
}

/// Every prefix and many random mutations of valid archives must produce an
/// error or a result, never a crash. A cheap, deterministic stand-in for the
/// libFuzzer harness in Fuzz/.
final class RobustnessTests: XCTestCase {
    func archives() -> [[UInt8]] {
        // Directory first: a prefix ending after it holds no file and must fail.
        // A prefix ending exactly at a block boundary is otherwise a valid,
        // shorter archive (RAR has no global entry count), as unrar agrees.
        let small = [TestFile(name: "a", contents: [], isDirectory: true),
                     TestFile(name: "a/b.jpg", contents: randomBytes(300, seed: 3))]
        return [RAR4Builder.build(small), RAR5Builder.build(small)]
    }

    func exercise(_ bytes: [UInt8]) {
        var limits = Limits.default
        limits.maxEntrySize = 1 << 20
        _ = try? convertToCBZ(source: DataSource(bytes), output: MemoryOutput(), limits: limits)
    }

    func testEveryTruncation() {
        // A missing end-of-archive block is tolerated, so exactly that prefix may succeed.
        let endBlockLengths = [7, 8] // RAR4 end block, RAR5 end header
        for (archive, endLength) in zip(archives(), endBlockLengths) {
            for length in 0..<archive.count where length != archive.count - endLength {
                let prefix = Array(archive.prefix(length))
                XCTAssertThrowsError(try convertToCBZ(source: DataSource(prefix), output: MemoryOutput(), limits: .default),
                                     "prefix \(length) unexpectedly converted")
            }
            let withoutEnd = Array(archive.prefix(archive.count - endLength))
            XCTAssertNoThrow(try convertToCBZ(source: DataSource(withoutEnd), output: MemoryOutput(), limits: .default))
        }
    }

    func testRandomMutations() {
        var generator = SeededGenerator(seed: 42)
        for archive in archives() {
            for _ in 0..<3_000 {
                var mutated = archive
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    let index = Int.random(in: 0..<mutated.count, using: &generator)
                    mutated[index] = UInt8.random(in: 0...255, using: &generator)
                }
                exercise(mutated)
            }
        }
    }
}

/// The extractor itself must verify CRCs: the conversion hands its CRC to
/// the ZIP writer and does not check the data a second time.
final class StoredExtractorTests: XCTestCase {
    func testDetectsCRCMismatchOnItsOwn() throws {
        for bytes in [RAR4Builder.build([TestFile(name: "a", contents: [1, 2, 3], crcOverride: 7)]),
                      RAR5Builder.build([TestFile(name: "a", contents: [1, 2, 3], crcOverride: 7)])] {
            let source = DataSource(bytes)
            let archive = try RARArchive(source: source, limits: .default)
            var received: [UInt8] = []
            XCTAssertThrowsError(try StoredExtractor.extract(archive.entries[0], from: source) { received += $0 }) {
                XCTAssertEqual($0 as? RARError, .badDataCRC(entry: "a"))
            }
            XCTAssertEqual(received, [1, 2, 3])
        }
    }

    func testRejectsInconsistentStoredSizes() throws {
        let source = DataSource(RAR4Builder.build([TestFile(name: "a", contents: [1, 2, 3])]))
        var entry = try RARArchive(source: source, limits: .default).entries[0]
        entry.unpackedSize = 4
        XCTAssertThrowsError(try StoredExtractor.extract(entry, from: source) { _ in })
        entry.unpackedSize = 3
        entry.method = 3
        XCTAssertThrowsError(try StoredExtractor.extract(entry, from: source) { _ in }) {
            XCTAssertEqual($0 as? RARError, .unsupportedCompression(method: 3))
        }
    }
}
