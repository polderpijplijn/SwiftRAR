// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import RARCore
import RARDecode

/// The streaming bit reader against the in-memory one.
final class StreamBitReaderTests: XCTestCase {
    func testMatchesBitReaderAcrossChunkBoundaries() throws {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<(StreamBitReader.chunkSize * 2 + 777)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        var reference = BitReader(bytes)
        var stream = try StreamBitReader(source: DataSource(bytes), offset: 0, count: UInt64(bytes.count))
        while reference.remainingBits > 0 {
            let width = min(Int.random(in: 0...32, using: &rng), reference.remainingBits)
            XCTAssertEqual(try stream.peekBits(32), try reference.peekBits(32))
            XCTAssertEqual(try stream.readBits(width), try reference.readBits(width))
        }
        XCTAssertEqual(stream.remainingBits, 0)
    }

    func testRangeInsideSourceAndEnd() throws {
        let bytes: [UInt8] = [0xFF, 0xA5, 0x3C, 0xFF]
        var stream = try StreamBitReader(source: DataSource(bytes), offset: 1, count: 2)
        XCTAssertEqual(try stream.readBits(12), 0xA53)
        // Peeking past the end yields zeros, not the byte after the range.
        XCTAssertEqual(try stream.peekBits(8), 0xC0)
        XCTAssertThrowsError(try stream.skipBits(5)) { XCTAssertEqual($0 as? RARError, .truncated) }
        XCTAssertEqual(try stream.readBits(4), 0xC)
        XCTAssertThrowsError(try stream.readBits(1)) { XCTAssertEqual($0 as? RARError, .truncated) }
    }

    func testRangeOutsideSourceThrows() {
        XCTAssertThrowsError(try StreamBitReader(source: DataSource([1, 2]), offset: 1, count: 2)) {
            XCTAssertEqual($0 as? RARError, .truncated)
        }
        XCTAssertThrowsError(try StreamBitReader(source: DataSource([1]), offset: .max, count: 2))
    }
}

/// The table-driven Huffman path against the bit-by-bit one.
final class HuffmanFastPathTests: XCTestCase {
    /// Random code lengths that are not over-subscribed (often incomplete).
    func randomLengths(_ rng: inout some RandomNumberGenerator) -> [UInt8] {
        while true {
            let count = Int.random(in: 1...320, using: &rng)
            let maxLength = UInt8.random(in: 1...15, using: &rng)
            let lengths = (0..<count).map { _ in
                Bool.random(using: &rng) ? 0 : UInt8.random(in: 1...maxLength, using: &rng)
            }
            if (try? HuffmanTable(codeLengths: lengths)) != nil { return lengths }
        }
    }

    func testFastPathMatchesSlowPath() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let table = try HuffmanTable(codeLengths: randomLengths(&rng))
            let bytes = (0..<64).map { _ in UInt8.random(in: 0...255, using: &rng) }
            var slow = BitReader(bytes)
            var fast = try StreamBitReader(source: DataSource(bytes), offset: 0, count: UInt64(bytes.count))
            while true {
                let expected = try? table.decodeSymbol(from: &slow)
                let actual = try? table.decodeSymbol(from: &fast)
                XCTAssertEqual(actual, expected)
                // After a failed code the position is meaningless.
                if expected == nil || actual == nil { break }
                XCTAssertEqual(fast.bitPosition, UInt64(slow.bitPosition))
            }
        }
    }

    func testCompleteTableDecodesEveryCode() throws {
        // Lengths 1, 2, 3, 4 ... 15, 15: complete, and half the codes are long.
        let lengths: [UInt8] = (1...15).map(UInt8.init) + [15]
        let table = try HuffmanTable(codeLengths: lengths)
        for symbol in lengths.indices {
            // Canonical code: `symbol` ones followed by a zero (the last one is all ones).
            let length = Int(lengths[symbol])
            var code = (1 << length) - 2
            if symbol == lengths.count - 1 { code = (1 << length) - 1 }
            let value = UInt32(code) << UInt32(32 - length)
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * $0)) }
            var reader = try StreamBitReader(source: DataSource(bytes), offset: 0, count: 4)
            XCTAssertEqual(try table.decodeSymbol(from: &reader), symbol)
            XCTAssertEqual(reader.bitPosition, UInt64(length))
        }
    }

    func testEmptyTableThrows() throws {
        var reader = try StreamBitReader(source: DataSource([0, 0]), offset: 0, count: 2)
        XCTAssertThrowsError(try HuffmanTable.empty.decodeSymbol(from: &reader))
    }
}

/// unpack29 on the rar-generated fixtures, beyond the oracle comparison.
final class Unpack29Tests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        let url = Tools.fixturesDirectory.appendingPathComponent("\(name).rar")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Tools.unavailable("fixture \(name) missing") }
        return url
    }

    /// The largest compressed entry of a fixture, plus the archive bytes.
    func largestCompressedEntry(_ name: String) throws -> (bytes: [UInt8], entry: RAREntry) {
        let bytes = [UInt8](try Data(contentsOf: fixture(name)))
        let archive = try RARArchive(source: DataSource(bytes), limits: .default)
        let compressed = archive.entries.filter { !$0.isStored && !$0.isDirectory }
        guard let entry = compressed.max(by: { $0.packedSize < $1.packedSize }) else {
            throw Tools.unavailable("no compressed entry in \(name)")
        }
        return (bytes, entry)
    }

    func decode(_ entry: RAREntry, in bytes: [UInt8], limits: Limits = .default) throws -> [UInt8] {
        var output: [UInt8] = []
        try RARDecoder.decode(entry, from: DataSource(bytes), limits: limits) { output += $0 }
        return output
    }

    func testCanDecode() throws {
        let (_, entry) = try largestCompressedEntry("rar4-m3")
        XCTAssertTrue(RARDecoder.canDecode(entry))
        var solid = entry
        solid.isSolid = true
        XCTAssertTrue(RARDecoder.canDecode(solid))
        var encrypted = entry
        encrypted.isEncrypted = true
        XCTAssertFalse(RARDecoder.canDecode(encrypted))
        var older = entry
        older.unpackVersion = 20
        XCTAssertFalse(RARDecoder.canDecode(older))
        var stored = entry
        stored.method = 0
        XCTAssertFalse(RARDecoder.canDecode(stored))
    }

    func testDecodesWholeEntryInBoundedChunks() throws {
        let (bytes, entry) = try largestCompressedEntry("rar4-m3-md64")
        XCTAssertGreaterThan(entry.unpackedSize, 0x40000, "entry must be larger than the window")
        var chunks: [Int] = []
        var crc = CRC32()
        try RARDecoder.decode(entry, from: DataSource(bytes), limits: .default) {
            chunks.append($0.count)
            crc.update($0)
        }
        XCTAssertEqual(UInt64(chunks.reduce(0, +)), entry.unpackedSize)
        XCTAssertEqual(crc.value, entry.crc32)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks.max() ?? 0, 0x40000)
    }

    func testDictionaryLimit() throws {
        let (bytes, entry) = try largestCompressedEntry("rar4-m3")
        var limits = Limits.default
        limits.maxDictionarySize = entry.dictionarySize - 1
        XCTAssertThrowsError(try decode(entry, in: bytes, limits: limits)) {
            XCTAssertEqual($0 as? RARError, .limitExceeded(.dictionarySize))
        }
    }

    func testTruncatedDataThrows() throws {
        let (bytes, entry) = try largestCompressedEntry("rar4-m3-md64")
        // A cut of a few bytes can leave the output complete (only the
        // end-of-file marker is lost), so start well inside the data.
        for cut in [100, 4_000, Int(entry.packedSize / 2), Int(entry.packedSize - 1)] {
            var short = entry
            short.packedSize = entry.packedSize - UInt64(cut)
            XCTAssertThrowsError(try decode(short, in: bytes), "cut \(cut)") {
                XCTAssertNotNil($0 as? RARError, "cut \(cut): \($0)")
            }
        }
    }

    func testOutputIsCappedAtUnpackedSize() throws {
        let (bytes, entry) = try largestCompressedEntry("rar4-m3")
        var shorter = entry
        shorter.unpackedSize -= 10
        // Fewer bytes reach the sink; the CRC then no longer matches.
        var count = 0
        XCTAssertThrowsError(try RARDecoder.decode(shorter, from: DataSource(bytes), limits: .default) {
            count += $0.count
        }) { XCTAssertEqual($0 as? RARError, .badDataCRC(entry: entry.rawName)) }
        XCTAssertEqual(UInt64(count), shorter.unpackedSize)
    }

    /// Flipped bits in the compressed data must end in a RARError, never a trap.
    func testCorruptedDataNeverTraps() throws {
        let (bytes, entry) = try largestCompressedEntry("rar4-m3")
        var rng = SystemRandomNumberGenerator()
        let start = Int(entry.dataOffset)
        let end = start + Int(entry.packedSize)
        for round in 0..<200 {
            var corrupt = bytes
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                // Mostly near the start, where the tables live.
                let span = round.isMultiple(of: 2) ? min(64, end - start) : end - start
                corrupt[Int.random(in: start..<(start + span), using: &rng)] ^= UInt8.random(in: 1...255, using: &rng)
            }
            do {
                _ = try decode(entry, in: corrupt)
            } catch is RARError {
            } catch {
                XCTFail("round \(round): non-RARError \(error)")
            }
        }
    }
}
