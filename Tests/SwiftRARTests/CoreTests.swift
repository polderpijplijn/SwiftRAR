// SPDX-License-Identifier: MIT

import XCTest
@testable import RARCore

final class CRC32Tests: XCTestCase {
    func testCheckValue() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testEmpty() {
        XCTAssertEqual(CRC32.checksum([UInt8]()), 0)
    }

    func testIncrementalMatchesOneShot() {
        let data = randomBytes(10_000, seed: 7)
        var crc = CRC32()
        crc.update(data[..<1])
        crc.update(data[1..<4097])
        crc.update(data[4097...])
        XCTAssertEqual(crc.value, CRC32.checksum(data))
    }
}

final class ByteReaderTests: XCTestCase {
    func testLittleEndianFields() throws {
        var reader = ByteReader([0x01, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(try reader.readU8(), 0x01)
        XCTAssertEqual(try reader.readU16(), 0x1234)
        XCTAssertEqual(try reader.readU32(), 0x1234_5678)
        XCTAssertThrowsError(try reader.readU8()) { XCTAssertEqual($0 as? RARError, .truncated) }
    }

    func testVInt() throws {
        var reader = ByteReader([0x05, 0x80, 0x01, 0xFF, 0x7F])
        XCTAssertEqual(try reader.readVInt(), 5)
        XCTAssertEqual(try reader.readVInt(), 128)
        XCTAssertEqual(try reader.readVInt(), 0x3FFF)
    }

    func testVIntMaximumAndOverflow() throws {
        var max = ByteReader([UInt8](repeating: 0xFF, count: 9) + [0x01])
        XCTAssertEqual(try max.readVInt(), UInt64.max)
        var overflow = ByteReader([UInt8](repeating: 0xFF, count: 9) + [0x02])
        XCTAssertThrowsError(try overflow.readVInt())
        var tooLong = ByteReader([UInt8](repeating: 0x80, count: 12))
        XCTAssertThrowsError(try tooLong.readVInt())
        var truncated = ByteReader([0x80, 0x80])
        XCTAssertThrowsError(try truncated.readVInt()) { XCTAssertEqual($0 as? RARError, .truncated) }
    }

    func testReadBytesRejectsNegativeAndHugeCounts() {
        var reader = ByteReader([1, 2, 3])
        XCTAssertThrowsError(try reader.readBytes(-1))
        XCTAssertThrowsError(try reader.readBytes(Int.max))
        XCTAssertEqual(reader.position, 0)
    }
}

final class BitReaderTests: XCTestCase {
    func testMSBFirst() throws {
        var reader = BitReader([0b1010_0000, 0xFF])
        XCTAssertEqual(try reader.readBits(1), 1)
        XCTAssertEqual(try reader.readBits(2), 0b01)
        XCTAssertEqual(try reader.peekBits(9), 0b0_0000_1111)
        XCTAssertEqual(try reader.readBits(13), 0b0_0000_1111_1111)
        XCTAssertEqual(reader.remainingBits, 0)
    }

    func testPeekPastEndIsZeroButConsumingThrows() throws {
        var reader = BitReader([0xFF])
        XCTAssertEqual(try reader.peekBits(16), 0xFF00)
        XCTAssertThrowsError(try reader.readBits(9)) { XCTAssertEqual($0 as? RARError, .truncated) }
        XCTAssertThrowsError(try reader.peekBits(33))
    }

    func testThirtyTwoBits() throws {
        var reader = BitReader([0xDE, 0xAD, 0xBE, 0xEF, 0x80])
        try reader.skipBits(1)
        XCTAssertEqual(try reader.readBits(32), 0xBD5B_7DDF)
    }
}

final class HuffmanTests: XCTestCase {
    func testCanonicalCode() throws {
        // Lengths A=2, B=1, C=3, D=3 -> B=0, A=10, C=110, D=111.
        let table = try HuffmanTable(codeLengths: [2, 1, 3, 3])
        var reader = BitReader([0b0101_1011, 0b1000_0000])
        XCTAssertEqual(try table.decodeSymbol(from: &reader), 1) // 0
        XCTAssertEqual(try table.decodeSymbol(from: &reader), 0) // 10
        XCTAssertEqual(try table.decodeSymbol(from: &reader), 2) // 110
        XCTAssertEqual(try table.decodeSymbol(from: &reader), 3) // 111
        XCTAssertEqual(try table.decodeSymbol(from: &reader), 1) // 0
    }

    func testOverSubscribedIsRejected() {
        XCTAssertThrowsError(try HuffmanTable(codeLengths: [1, 1, 1]))
        XCTAssertThrowsError(try HuffmanTable(codeLengths: [16]))
    }

    func testIncompleteCodeGapThrows() throws {
        let table = try HuffmanTable(codeLengths: [1]) // only code "0"
        var reader = BitReader([0xFF, 0xFF])
        XCTAssertThrowsError(try table.decodeSymbol(from: &reader))
    }

    func testEmptyTableThrowsInsteadOfTrapping() throws {
        let table = try HuffmanTable(codeLengths: [0, 0])
        var reader = BitReader([0x00, 0x00])
        XCTAssertThrowsError(try table.decodeSymbol(from: &reader))
    }

    func testRunningOutOfBitsThrows() throws {
        let table = try HuffmanTable(codeLengths: [2, 1, 3, 3])
        var reader = BitReader([0b1111_1111])
        try reader.skipBits(6) // "11" left: a prefix of C/D, but the third bit is missing
        XCTAssertThrowsError(try table.decodeSymbol(from: &reader))
    }
}

final class DOSTimeTests: XCTestCase {
    func testRoundTrip() throws {
        let packed: UInt32 = (UInt32(2024 - 1980) << 25) | (5 << 21) | (17 << 16) | (12 << 11) | (34 << 5) | 28
        let date = try XCTUnwrap(DOSTime.date(fromPacked: packed))
        XCTAssertEqual(DOSTime.packed(from: date), packed)
    }

    func testInvalidValuesAndClamping() {
        XCTAssertNil(DOSTime.date(fromPacked: 0)) // month 0
        XCTAssertEqual(DOSTime.packed(from: Date(timeIntervalSince1970: 0)) >> 16, (0 << 9) | (1 << 5) | 1)
    }
}

final class NameSanitizerTests: XCTestCase {
    func sanitize(_ name: String) throws -> String {
        try NameSanitizer.sanitize(name, maxLength: 1024)
    }

    func testTraversalAndSeparators() throws {
        XCTAssertEqual(try sanitize("..\\..\\etc\\passwd"), "etc/passwd")
        XCTAssertEqual(try sanitize("../../../tmp/x"), "tmp/x")
        XCTAssertEqual(try sanitize("/absolute/path.jpg"), "absolute/path.jpg")
        XCTAssertEqual(try sanitize("a/./b//c/../d"), "a/b/c/d")
        XCTAssertEqual(try sanitize("C:\\Comics\\01.jpg"), "Comics/01.jpg")
        XCTAssertEqual(try sanitize("één/ünïcode.png"), "één/ünïcode.png")
    }

    func testRejections() {
        XCTAssertThrowsError(try sanitize(".."))
        XCTAssertThrowsError(try sanitize("/"))
        XCTAssertThrowsError(try sanitize(""))
        XCTAssertThrowsError(try sanitize("a\u{0}b"))
        XCTAssertThrowsError(try sanitize("line\nbreak"))
        XCTAssertThrowsError(try NameSanitizer.sanitize(String(repeating: "x", count: 20), maxLength: 10)) {
            XCTAssertEqual($0 as? RARError, .limitExceeded(.nameLength))
        }
    }
}

final class FormatDetectionTests: XCTestCase {
    func detect(_ bytes: [UInt8]) throws -> ArchiveFormat {
        try ArchiveFormat.detect(DataSource(bytes))
    }

    func testMagicBytes() throws {
        XCTAssertEqual(try detect([0x50, 0x4B, 0x03, 0x04, 0, 0]), .zip)
        XCTAssertEqual(try detect([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0xCF]), .rar4)
        XCTAssertEqual(try detect([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]), .rar5)
    }

    func testUnknownAndUnsupported() {
        XCTAssertThrowsError(try detect([])) { XCTAssertEqual($0 as? RARError, .unknownFormat) }
        XCTAssertThrowsError(try detect([0x52, 0x61])) { XCTAssertEqual($0 as? RARError, .unknownFormat) }
        XCTAssertThrowsError(try detect(Array("%PDF-1.7".utf8))) { XCTAssertEqual($0 as? RARError, .unknownFormat) }
        XCTAssertThrowsError(try detect([0x52, 0x45, 0x7E, 0x5E, 0, 0])) {
            XCTAssertEqual($0 as? RARError, .unsupportedFormat("RAR 1.4"))
        }
        XCTAssertThrowsError(try detect([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x02, 0x00])) {
            XCTAssertEqual($0 as? RARError, .unsupportedFormat("unknown RAR version"))
        }
    }

    func testDataSourceBounds() {
        let source = DataSource([1, 2, 3])
        XCTAssertThrowsError(try source.read(at: 2, count: 2)) { XCTAssertEqual($0 as? RARError, .truncated) }
        XCTAssertThrowsError(try source.read(at: UInt64.max, count: 1))
        XCTAssertThrowsError(try source.read(at: 0, count: -1))
        XCTAssertEqual(try source.read(at: 3, count: 0), [])
    }
}
