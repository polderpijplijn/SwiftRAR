// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import RARCore
@testable import RARDecode
import SwiftRAR

/// RAR5 LZ and filters (unpack50, phase 5).
final class Unpack50Tests: XCTestCase {
    let fixtures = PPMdTests()

    /// Solid RAR5 fixtures pack near-copies beyond the default ratio limit
    /// (see `FixtureTests.limitOverrides`).
    var looseLimits: Limits {
        var limits = Limits.default
        limits.maxCompressionRatio = 2_000
        return limits
    }

    func coverage(_ name: String) throws -> RAR5Coverage {
        try fixtures.decodeAll(fixtures.fixture(name), limits: looseLimits).rar5Coverage
    }

    // MARK: - Fixtures

    /// A fixture that rar packed differently would test nothing, so each one
    /// must go through the paths it is meant for. RAR 7.23 never emits E8E9
    /// or ARM and starts every block with new tables; those paths are
    /// covered by hand-built streams below.
    func testFixturesTakeTheirPaths() throws {
        let plain = try coverage("rar5-m3")
        XCTAssertGreaterThan(plain.repeatLast, 0)
        XCTAssertGreaterThan(plain.oldDistances, 0)
        XCTAssertGreaterThan(plain.lengthBonus, 0)
        XCTAssertEqual(plain.zeroFills, 0)

        let solid = try coverage("rar5-s")
        XCTAssertEqual(solid.solidContinuations, 5)

        // long.txt is four times the 256 KB window.
        let wrapped = try coverage("rar5-m3-md128")
        XCTAssertGreaterThan(wrapped.windowWraps, 0)

        let big = try coverage("rar5-m3-big")
        XCTAssertGreaterThan(big.blocks, 40)
        XCTAssertGreaterThan(big.longDistances, 0)
        XCTAssertTrue(big.filters.isEmpty)

        // Filtered blocks across window wraps.
        let e8 = try coverage("rar5-flt-e8")
        XCTAssertGreaterThan(e8.filters[.e8, default: 0], 0)
        XCTAssertGreaterThan(e8.windowWraps, 0)

        let delta = try coverage("rar5-flt-delta")
        XCTAssertGreaterThan(delta.filters[.delta, default: 0], 0)

        let solidFiltered = try coverage("rar5-s-flt")
        XCTAssertGreaterThan(solidFiltered.filters[.delta, default: 0], 0)
        XCTAssertEqual(solidFiltered.solidContinuations, 4)

        // The symlink has no data and does not interrupt the solid stream.
        let link = try coverage("rar5-s-link")
        XCTAssertEqual(link.solidContinuations, 1)
    }

    /// `rar5-m3-big` asks for a 2 MiB dictionary.
    func testDictionaryLimit() throws {
        var limits = looseLimits
        limits.maxDictionarySize = 1 << 20
        XCTAssertThrowsError(try fixtures.decodeAll(fixtures.fixture("rar5-m3-big"), limits: limits)) {
            XCTAssertEqual($0 as? RARError, .limitExceeded(.dictionarySize))
        }
    }

    /// Algorithm version 0 is RAR 5.0 with 4 dictionary bits. Version 1 is
    /// RAR 7.0 with 5 bits and a fraction, unless the compat flag says the
    /// data uses the RAR 5.0 algorithm.
    func testCompressionInformation() throws {
        func entry(_ compression: UInt64) throws -> RAREntry {
            let file = TestFile(name: "a", contents: [1], rar5Compression: compression)
            let archive = try RARArchive(source: DataSource(RAR5Builder.build([file])), limits: .default)
            return try XCTUnwrap(archive.entries.first)
        }
        let method3: UInt64 = 3 << 7
        let rar5 = try entry(method3 | 0x10 << 10 | 3 << 10)    // bit 4 of the size is not RAR 5.0's
        XCTAssertEqual(rar5.unpackVersion, 50)
        XCTAssertEqual(rar5.dictionarySize, 0x20000 << 3)
        let rar7 = try entry(1 | method3 | 3 << 10 | 4 << 15)    // 1 MiB + 4/32
        XCTAssertEqual(rar7.unpackVersion, 70)
        XCTAssertEqual(rar7.dictionarySize, (1 << 20) + (1 << 20) / 32 * 4)
        let compat = try entry(1 | method3 | 3 << 10 | 0x10_0000)
        XCTAssertEqual(compat.unpackVersion, 50)
        XCTAssertThrowsError(try entry(2 | method3))
    }

    // MARK: - Hand-built streams

    /// Literals, a match, repeat-last (257) and an old distance (258), all in
    /// one block. Decoded as RAR 5.0 and as RAR 7.0, whose only difference
    /// is the 80-code distance table.
    func testHandBuiltStreamDecodes() throws {
        for extended in [false, true] {
            var stream = RAR5Stream(extended: extended)
            stream.literals(Array("abcdef".utf8))
            stream.match(length: 4, distance: 6)        // abcd
            stream.repeatLast()                         // efab
            stream.literals(Array("XY".utf8))
            stream.oldDistance(0, length: 3)            // distance 6: efa
            let output = try decode(stream, extended: extended, size: 19)
            XCTAssertEqual(String(decoding: output, as: UTF8.self), "abcdefabcdefabXYefa", "extended: \(extended)")
        }
    }

    /// Distance slot 64 and up only exists in the RAR 7.0 table. Beyond the
    /// data such a distance produces zeros, as in UnRAR.
    func testExtendedDistanceSlotProducesZerosBeyondTheData() throws {
        var stream = RAR5Stream(extended: true)
        stream.literals([1, 2, 3])
        stream.match(length: 2, distanceSlot: 70, extra: 0) // plus 3 for the distance
        XCTAssertEqual(try decode(stream, extended: true, size: 8), [1, 2, 3, 0, 0, 0, 0, 0])
    }

    /// A distance above 2^20 has more than 16 high bits, which the decoder
    /// reads in two parts. 5 MiB of filler between a marker and its copy, so
    /// the distance has bits set in both parts.
    func testLongDistanceReadsItsBitsInTwoParts() throws {
        let marker = Array("0123456789abcdef".utf8)
        let target = (5 << 20) + 12_345
        var stream = RAR5Stream(extended: false)
        stream.literals(marker)
        stream.literals([0x55])
        var produced = marker.count + 1
        while produced < target {
            let length = min(4097, target - produced)
            guard length >= 2 else { break }
            stream.match(length: length, distance: 1)
            produced += length
        }
        stream.match(length: marker.count, distance: produced)
        let output = try decode(stream, extended: false, size: UInt64(produced + marker.count),
                                dictionaryBits: 6) // 8 MiB
        XCTAssertEqual(Array(output.suffix(marker.count)), marker)
        XCTAssertEqual(output.count, produced + marker.count)
    }

    /// The length bonus starts above 0x100, 0x2000 and 0x40000: a match at
    /// exactly one past each boundary gets it, one at the boundary does not.
    func testLengthBonusBoundaries() throws {
        for distance in [0x100, 0x101, 0x2000, 0x2001, 0x40000, 0x40001] {
            var stream = RAR5Stream(extended: false)
            stream.literals([0x11, 0x22])
            var produced = 2
            while produced < distance {
                let length = min(4097, distance - produced)
                if length < 2 { stream.literals([0x22]); produced += 1; continue }
                stream.match(length: length, distance: 1)
                produced += length
            }
            stream.match(length: 7, distance: distance)
            let output = try decode(stream, extended: false, size: UInt64(produced + 7), dictionaryBits: 2)
            XCTAssertEqual(output.count, produced + 7, "distance \(distance)")
            XCTAssertEqual(Array(output.suffix(7)), [0x11] + [UInt8](repeating: 0x22, count: 6), "distance \(distance)")
        }
    }

    /// A non-solid entry reuses the window of the entry before it, but a
    /// distance reaching before its own first byte must give zeros, never
    /// the stale bytes of the other entry.
    func testNonSolidEntryNeverSeesTheWindowBefore() throws {
        // First entry: 256 KiB of 0x55, filling the whole window.
        var first = RAR5Stream(extended: false)
        first.literals([0x55])
        var produced = 1
        while produced < 0x40000 {
            let length = min(4097, 0x40000 - produced)
            if length < 2 { first.literals([0x55]); produced += 1; continue }
            first.match(length: length, distance: 1)
            produced += length
        }
        // Second entry: three bytes, then a match one byte too far back.
        var second = RAR5Stream(extended: false)
        second.literals([1, 2, 3])
        second.match(length: 2, distance: 4)

        var files = [first, second].enumerated().map { index, stream in
            TestFile(name: "\(index)", contents: stream.bytes(), rar5Compression: 3 << 7)
        }
        for index in files.indices { files[index].crcOverride = 0 }
        let source = DataSource(RAR5Builder.build(files))
        let archive = try RARArchive(source: source, limits: .default)
        let session = RARDecoder.Session(limits: .default)
        var outputs: [[UInt8]] = []
        for (entry, size) in zip(archive.entries, [UInt64(produced), 5]) {
            var entry = entry
            entry.unpackedSize = size
            var output: [UInt8] = []
            XCTAssertThrowsError(try session.decode(entry, from: source) { output += $0 })
            outputs.append(output)
        }
        XCTAssertEqual(outputs.first?.count, produced)
        XCTAssertEqual(outputs.last, [1, 2, 3, 0, 0])
    }

    /// Filters registered in the stream, applied by the write path: ARM and
    /// E8E9 (which rar never emits) and delta with three channels.
    func testHandBuiltFilters() throws {
        // ARM: BL at offset 4 with target 0x10 becomes 0x10 - 4/4.
        var arm = RAR5Stream(extended: false)
        arm.filter(start: 0, length: 8, type: .arm)
        arm.literals([0, 0, 0, 0, 0x10, 0, 0, 0xEB])
        XCTAssertEqual(try decode(arm, extended: false, size: 8), [0, 0, 0, 0, 0x0F, 0, 0, 0xEB])

        // E8E9: a JMP is converted too; the filter starts 2 bytes in.
        var e8e9 = RAR5Stream(extended: false)
        e8e9.filter(start: 2, length: 6, type: .e8e9)
        e8e9.literals([0xAA, 0xBB, 0xE9, 0x10, 0, 0, 0, 0x77])
        // Offset = position after the opcode (1) + file offset (2).
        XCTAssertEqual(try decode(e8e9, extended: false, size: 8), [0xAA, 0xBB, 0xE9, 0x0D, 0, 0, 0, 0x77])

        var delta = RAR5Stream(extended: false)
        delta.filter(start: 0, length: 6, type: .delta, channels: 3)
        delta.literals([1, 2, 3, 4, 5, 6])
        // Channel 0 gets [1, 2], channel 1 [3, 4], channel 2 [5, 6].
        XCTAssertEqual(try decode(delta, extended: false, size: 6), [255, 253, 251, 253, 249, 245])
    }

    /// A filter type above ARM: UnRAR writes nothing for the block, which
    /// can only end in a CRC error. We stop right there.
    func testUnknownFilterTypeIsCorrupt() {
        var stream = RAR5Stream(extended: false)
        stream.filter(start: 0, length: 4, rawType: 5)
        stream.literals([1, 2, 3, 4])
        XCTAssertThrowsError(try decode(stream, extended: false, size: 4)) {
            XCTAssertEqual($0 as? RARError, .corruptData("filter type 5"))
        }
    }

    /// A table-less second block keeps the tables of the first; a block
    /// header with a bad checksum or 4 size bytes is corrupt.
    func testBlockHeaders() throws {
        var stream = RAR5Stream(extended: false)
        stream.literals([7, 8])
        stream.newBlock(tables: false)
        stream.literals([9])
        XCTAssertEqual(try decode(stream, extended: false, size: 3), [7, 8, 9])

        var badChecksum = RAR5Stream(extended: false)
        badChecksum.literals([1])
        badChecksum.corruptChecksum = true
        XCTAssertThrowsError(try decode(badChecksum, extended: false, size: 1)) {
            XCTAssertEqual($0 as? RARError, .corruptData("block header checksum"))
        }

        XCTAssertThrowsError(try decode(packed: [UInt8(0x80 | 0x18), 0, 0, 0, 0, 0], size: 1)) {
            XCTAssertEqual($0 as? RARError, .corruptData("block size of 4 bytes"))
        }
    }

    /// The first block of a non-solid entry must bring tables.
    func testFirstBlockWithoutTablesIsCorrupt() {
        var stream = RAR5Stream(extended: false)
        stream.firstBlockHasTables = false
        stream.literals([1])
        XCTAssertThrowsError(try decode(stream, extended: false, size: 1)) {
            XCTAssertEqual($0 as? RARError, .corruptData("block without tables"))
        }
    }

    /// "Repeat the previous length" cannot be the first table entry.
    func testRepeatAtTableStartIsCorrupt() {
        var stream = RAR5Stream(extended: false)
        stream.repeatAtTableStart = true
        stream.literals([1])
        XCTAssertThrowsError(try decode(stream, extended: false, size: 1)) {
            XCTAssertEqual($0 as? RARError, .corruptData("table repeats before first length"))
        }
    }

    // MARK: - Filters

    func testE8Filter() {
        func e8(_ bytes: [UInt8], offset: UInt32 = 0, e9: Bool = false) -> [UInt8] {
            RAR5Filters.e8(bytes, fileOffset: offset, alsoE9: e9)
        }
        // Positive address below 16 MiB: minus (position + file offset).
        XCTAssertEqual(e8([0xE8, 0x10, 0, 0, 0, 0]), [0xE8, 0x0F, 0, 0, 0, 0])
        XCTAssertEqual(e8([0xE8, 0, 2, 0, 0, 0], offset: 0x100), [0xE8, 0xFF, 0, 0, 0, 0])
        // Five bytes are enough, four are not.
        XCTAssertEqual(e8([0xE8, 0x10, 0, 0, 0]), [0xE8, 0x0F, 0, 0, 0])
        XCTAssertEqual(e8([0xE8, 0x10, 0, 0]), [0xE8, 0x10, 0, 0])
        // -1 plus the offset is not negative: add 16 MiB.
        XCTAssertEqual(e8([0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0]), [0xE8, 0xFF, 0xFF, 0xFF, 0x00, 0])
        // -16 plus the offset stays negative: unchanged.
        XCTAssertEqual(e8([0xE8, 0xF0, 0xFF, 0xFF, 0xFF, 0]), [0xE8, 0xF0, 0xFF, 0xFF, 0xFF, 0])
        // 16 MiB and up: unchanged.
        XCTAssertEqual(e8([0xE8, 0, 0, 0, 1, 0]), [0xE8, 0, 0, 0, 1, 0])
        // The offset wraps at 16 MiB.
        XCTAssertEqual(e8([0xE8, 0x10, 0, 0, 0, 0], offset: 0xFF_FFFF), [0xE8, 0x10, 0, 0, 0, 0])
        // The address bytes are skipped, even when one of them is E8.
        XCTAssertEqual(e8([0xE8, 0xE8, 0, 0, 0, 0xE8, 0x10, 0, 0, 0, 0]),
                       [0xE8, 0xE7, 0, 0, 0, 0xE8, 0x0A, 0, 0, 0, 0])
        // E9 only with E8E9.
        XCTAssertEqual(e8([0xE9, 0x10, 0, 0, 0, 0]), [0xE9, 0x10, 0, 0, 0, 0])
        XCTAssertEqual(e8([0xE9, 0x10, 0, 0, 0, 0], e9: true), [0xE9, 0x0F, 0, 0, 0, 0])
    }

    func testARMFilter() {
        let words: [UInt8] = [0x10, 0, 0, 0xEB, 0x10, 0, 0, 0xEB, 0, 0, 0, 0xEB, 0x10, 0, 0, 0xEA, 1, 2, 3]
        XCTAssertEqual(RAR5Filters.arm(words, fileOffset: 0),
                       [0x10, 0, 0, 0xEB, 0x0F, 0, 0, 0xEB, 0xFE, 0xFF, 0xFF, 0xEB, 0x10, 0, 0, 0xEA, 1, 2, 3])
        XCTAssertEqual(Array(RAR5Filters.arm(words, fileOffset: 8).prefix(8)), [0x0E, 0, 0, 0xEB, 0x0D, 0, 0, 0xEB])
    }

    func testDeltaFilter() {
        XCTAssertEqual(RAR5Filters.delta([1, 2, 3, 4], channels: 2), [255, 253, 253, 249])
        // Odd length: channel 0 has one byte more.
        XCTAssertEqual(RAR5Filters.delta([1, 1, 1, 2, 2], channels: 2), [255, 254, 254, 252, 253])
        XCTAssertEqual(RAR5Filters.delta([], channels: 32), [])
    }

    // MARK: - Corruption

    func testCorruptedRAR5DataNeverTraps() throws {
        var rng = SystemRandomNumberGenerator()
        for name in ["rar5-m3", "rar5-s", "rar5-flt-delta", "rar5-flt-e8", "rar5-s-link"] {
            let bytes = try fixtures.fixture(name)
            let archive = try RARArchive(source: DataSource(bytes), limits: looseLimits)
            let compressed = archive.entries.filter { !$0.isStored && !$0.isDirectory && $0.packedSize > 8 }
            for round in 0..<8 {
                guard let entry = compressed.randomElement(using: &rng) else { break }
                var corrupt = bytes
                let start = Int(entry.dataOffset)
                let span = round.isMultiple(of: 2) ? min(64, Int(entry.packedSize)) : Int(entry.packedSize)
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    corrupt[Int.random(in: start..<(start + span), using: &rng)] ^= UInt8.random(in: 1...255, using: &rng)
                }
                assertOnlyRARErrors(corrupt, "\(name) round \(round)")
            }
            for entry in compressed {
                let cut = Int(entry.dataOffset) + Int(entry.packedSize) / 2
                assertOnlyRARErrors(Array(bytes[..<cut]), "\(name) cut in \(entry.rawName)")
            }
        }
    }

    func assertOnlyRARErrors(_ bytes: [UInt8], _ label: String) {
        let start = Date()
        do {
            try fixtures.decodeAll(bytes, limits: looseLimits)
        } catch is RARError {
        } catch {
            XCTFail("\(label): non-RARError \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 30, label)
    }

    // MARK: - Helpers

    func decode(_ stream: RAR5Stream, extended: Bool, size: UInt64, dictionaryBits: UInt64 = 0) throws -> [UInt8] {
        try decode(packed: stream.bytes(), size: size, version: extended ? 1 : 0, dictionaryBits: dictionaryBits)
    }

    /// One hand-built compressed RAR5 entry whose data is `packed`. The CRC
    /// is not checked here: the output is compared directly.
    func decode(packed: [UInt8], size: UInt64, version: UInt64 = 0, dictionaryBits: UInt64 = 0) throws -> [UInt8] {
        let compression = version | 3 << 7 | dictionaryBits << 10
        var file = TestFile(name: "a.bin", contents: packed, rar5Compression: compression)
        file.crcOverride = 0
        let source = DataSource(RAR5Builder.build([file]))
        let archive = try RARArchive(source: source, limits: .default)
        var entry = try XCTUnwrap(archive.entries.first)
        entry.unpackedSize = size
        var limits = Limits.default
        limits.maxEntrySize = 64 << 20
        var output: [UInt8] = []
        do {
            try RARDecoder.decode(entry, from: source, limits: limits) { output += $0 }
        } catch RARError.badDataCRC {
            return output
        }
        XCTFail("CRC 0 matched")
        return output
    }
}

/// Writes a RAR5 compressed stream with fixed, flat Huffman tables, to
/// reach paths that rar never writes. Test-only: it encodes the symbols it
/// is given and finds no matches, so it is not a compressor.
struct RAR5Stream {
    private enum Item {
        case bits(UInt64, Int)
        case block(tables: Bool)
    }

    let extended: Bool
    var firstBlockHasTables = true
    var corruptChecksum = false
    var repeatAtTableStart = false
    private var items: [Item] = []

    // Flat tables: every symbol of an alphabet gets the same code length,
    // so a symbol's code is its number in that many bits.
    static let literalBits = 9      // 306 symbols
    static let distanceBits = 7     // 64 or 80 symbols
    static let lowDistanceBits = 4  // 16 symbols
    static let repeatBits = 6       // 44 symbols
    static let tableLengthBits = 5  // 20 bit-length symbols

    init(extended: Bool) {
        self.extended = extended
    }

    mutating func literals(_ bytes: [UInt8]) {
        for byte in bytes { items.append(.bits(UInt64(byte), Self.literalBits)) }
    }

    mutating func repeatLast() {
        items.append(.bits(257, Self.literalBits))
    }

    mutating func oldDistance(_ index: Int, length: Int) {
        items.append(.bits(UInt64(258 + index), Self.literalBits))
        let (slot, extra, bits) = Self.lengthSlot(length)
        items.append(.bits(UInt64(slot), Self.repeatBits))
        items.append(.bits(UInt64(extra), bits))
    }

    /// A match; `length` is the decoded length, bonus included.
    mutating func match(length: Int, distance: Int) {
        var base = length
        if distance > 0x100 { base -= 1 }
        if distance > 0x2000 { base -= 1 }
        if distance > 0x40000 { base -= 1 }
        let value = distance - 1
        var slot = 0
        while slot < 79, Self.distanceBase(slot + 1) <= value { slot += 1 }
        match(length: base, distanceSlot: slot, extra: value - Self.distanceBase(slot))
    }

    /// A match with an explicit distance slot; `length` without bonus.
    mutating func match(length: Int, distanceSlot slot: Int, extra: Int) {
        let (lengthSlot, lengthExtra, lengthBits) = Self.lengthSlot(length)
        items.append(.bits(UInt64(262 + lengthSlot), Self.literalBits))
        items.append(.bits(UInt64(lengthExtra), lengthBits))
        items.append(.bits(UInt64(slot), Self.distanceBits))
        guard slot >= 4 else { return }
        let bits = slot / 2 - 1
        if bits < 4 {
            items.append(.bits(UInt64(extra), bits))
        } else {
            items.append(.bits(UInt64(extra >> 4), bits - 4))
            items.append(.bits(UInt64(extra & 15), Self.lowDistanceBits))
        }
    }

    mutating func filter(start: Int, length: Int, type: RAR5Filter, channels: Int = 1) {
        filter(start: start, length: length, rawType: type.rawValue, channels: channels)
    }

    mutating func filter(start: Int, length: Int, rawType: Int, channels: Int = 1) {
        items.append(.bits(256, Self.literalBits))
        for value in [start, length] {
            items.append(.bits(3, 2)) // four bytes
            for index in 0..<4 { items.append(.bits(UInt64(value >> (8 * index) & 0xFF), 8)) }
        }
        items.append(.bits(UInt64(rawType), 3))
        if rawType == RAR5Filter.delta.rawValue { items.append(.bits(UInt64(channels - 1), 5)) }
    }

    mutating func newBlock(tables: Bool) {
        items.append(.block(tables: tables))
    }

    static func distanceBase(_ slot: Int) -> Int {
        slot < 4 ? slot : (2 | slot & 1) << (slot / 2 - 1)
    }

    static func lengthSlot(_ length: Int) -> (slot: Int, extra: Int, bits: Int) {
        let value = length - 2
        if value < 8 { return (value, 0, 0) }
        for slot in stride(from: 43, through: 8, by: -1) {
            let bits = slot / 4 - 1
            let base = (4 | slot & 3) << bits
            if value >= base { return (slot, value - base, bits) }
        }
        return (0, 0, 0)
    }

    func bytes() -> [UInt8] {
        var blocks: [(tables: Bool, items: [(UInt64, Int)])] = [(firstBlockHasTables, [])]
        for item in items {
            switch item {
            case .bits(let value, let count): blocks[blocks.count - 1].items.append((value, count))
            case .block(let tables): blocks.append((tables, []))
            }
        }
        var out: [UInt8] = []
        for (index, block) in blocks.enumerated() {
            var body = BitWriter()
            if block.tables { writeTables(&body) }
            for (value, count) in block.items { body.write(value, count) }
            let (data, lastBits) = body.finish()
            let size = data.count
            var flags = (block.tables ? 0x80 : 0) | (index == blocks.count - 1 ? 0x40 : 0)
            flags |= 2 << 3 | (lastBits - 1)    // three size bytes
            var checksum = (0x5A ^ flags ^ size ^ (size >> 8) ^ (size >> 16)) & 0xFF
            if corruptChecksum { checksum ^= 1 }
            out += [UInt8(flags), UInt8(checksum), UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF)]
            out += data
        }
        return out + [0, 0, 0, 0] // padding the decoder may look ahead into
    }

    private func writeTables(_ writer: inout BitWriter) {
        // Bit-length table: all 20 symbols get 5 bits.
        for _ in 0..<20 { writer.write(UInt64(Self.tableLengthBits), 4) }
        let distances = extended ? 80 : 64
        var lengths = [Int](repeating: Self.literalBits, count: 306)
        lengths += [Int](repeating: Self.distanceBits, count: distances)
        lengths += [Int](repeating: Self.lowDistanceBits, count: 16)
        lengths += [Int](repeating: Self.repeatBits, count: 44)
        if repeatAtTableStart {
            writer.write(16, Self.tableLengthBits)
            writer.write(0, 3)
        }
        for length in lengths { writer.write(UInt64(length), Self.tableLengthBits) }
    }
}

/// MSB-first bit writer.
struct BitWriter {
    private var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: UInt64, _ count: Int) {
        guard count > 0 else { return }
        for shift in stride(from: count - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if value >> UInt64(shift) & 1 == 1 {
                bytes[bytes.count - 1] |= UInt8(0x80 >> (bitCount % 8))
            }
            bitCount += 1
        }
    }

    /// The bytes and the number of bits used in the last one (1...8).
    func finish() -> ([UInt8], Int) {
        let used = bitCount % 8
        return (bytes, used == 0 ? 8 : used)
    }
}
