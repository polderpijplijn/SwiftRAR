// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import RARCore
@testable import RARDecode
import SwiftRAR

/// RarVM standard filters and solid archives (phase 3).
final class FilterTests: XCTestCase {
    func fixture(_ name: String) throws -> [UInt8] {
        let url = Tools.fixturesDirectory.appendingPathComponent("\(name).rar")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Tools.unavailable("fixture \(name) missing") }
        return [UInt8](try Data(contentsOf: url))
    }

    /// Decodes every compressed entry in archive order with one session.
    @discardableResult
    func decodeAll(_ bytes: [UInt8]) throws -> RARDecoder.Session {
        let source = DataSource(bytes)
        let archive = try RARArchive(source: source, limits: .default)
        let session = RARDecoder.Session(limits: .default)
        for entry in archive.entries where !entry.isStored && !entry.isDirectory {
            try session.decode(entry, from: source) { _ in }
        }
        return session
    }

    // MARK: - Fixtures

    /// A fixture that rar packed without the filter would test nothing, so
    /// each one must actually run the filters it is named for. RAR 6.24
    /// never emits E8E9 or Itanium; see the relational tests below.
    func testFixturesRunTheirFilters() throws {
        let expected: [String: Set<StandardFilter>] = [
            "rar4-m3-flt": [.delta],
            "rar4-s-flt": [.audio, .delta],
            "rar4-flt-e8": [.e8],
            "rar4-flt-audio": [.audio],
            "rar4-flt-delta": [.delta],
            "rar4-flt-rgb": [.rgb],
            "rar4-m3-big": [],
            "rar4-s": [],
        ]
        for (name, filters) in expected {
            let applied = try decodeAll(fixture(name)).appliedFilters
            XCTAssertEqual(Set(applied.keys), filters, name)
        }
    }

    /// The solid fixtures share data across entries: at least one entry
    /// cannot be decoded on its own, without the ones before it.
    func testSolidEntriesNeedTheirPredecessors() throws {
        for name in ["rar4-s", "rar4-s-flt"] {
            let bytes = try fixture(name)
            let archive = try RARArchive(source: DataSource(bytes), limits: .default)
            let solid = archive.entries.filter { $0.isSolid && !$0.isStored && !$0.isDirectory && $0.unpackedSize > 0 }
            XCTAssertFalse(solid.isEmpty, name)
            let alone = solid.filter { entry in
                (try? RARDecoder.decode(entry, from: DataSource(bytes), limits: .default) { _ in }) == nil
            }
            XCTAssertFalse(alone.isEmpty, "\(name): every solid entry decodes on its own")
        }
    }

    /// After a failed entry, the rest of the solid stream is refused.
    func testSessionRefusesSolidEntryAfterFailure() throws {
        let bytes = try fixture("rar4-s")
        let source = DataSource(bytes)
        let archive = try RARArchive(source: source, limits: .default)
        let compressed = archive.entries.filter { !$0.isStored && !$0.isDirectory }
        guard compressed.count >= 2, var first = compressed.first else { throw Tools.unavailable("needs two entries") }
        first.crc32 = (first.crc32 ?? 0) ^ 1
        let session = RARDecoder.Session(limits: .default)
        XCTAssertThrowsError(try session.decode(first, from: source) { _ in })
        XCTAssertThrowsError(try session.decode(compressed[1], from: source) { _ in }) {
            XCTAssertEqual($0 as? RARError, .corruptData("solid stream broken by an earlier entry"))
        }
    }

    /// Flipped bytes and cuts in filtered and solid data end in a RARError,
    /// never in a trap.
    func testCorruptedFilteredAndSolidDataNeverTraps() throws {
        var rng = SystemRandomNumberGenerator()
        for name in ["rar4-m3-flt", "rar4-s-flt", "rar4-flt-e8", "rar4-flt-rgb", "rar4-flt-audio"] {
            let bytes = try fixture(name)
            let archive = try RARArchive(source: DataSource(bytes), limits: .default)
            let compressed = archive.entries.filter { !$0.isStored && !$0.isDirectory && $0.packedSize > 0 }
            for round in 0..<12 {
                guard let entry = compressed.randomElement(using: &rng) else { break }
                var corrupt = bytes
                let start = Int(entry.dataOffset)
                let span = round.isMultiple(of: 2) ? min(256, Int(entry.packedSize)) : Int(entry.packedSize)
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
        do {
            try decodeAll(bytes)
        } catch is RARError {
        } catch {
            XCTFail("\(label): non-RARError \(error)")
        }
    }

    // MARK: - Filter header

    /// Every length class of `RarVM::ReadData`.
    func testReadData() {
        // (bit string, value, bits consumed)
        let cases: [(String, UInt32, Int)] = [
            ("00" + "1011", 0xB, 6),
            ("01" + "0000" + "10100101", 0xFFFF_FFA5, 14),
            ("01" + "00110110", 0x36, 10),
            ("10" + "1100101011111110", 0xCAFE, 18),
            ("11" + "11011110101011011011111011101111", 0xDEAD_BEEF, 34),
        ]
        for (bits, value, consumed) in cases {
            var input = VMBitInput(pack("1" + bits))
            input.skip(1) // start off a byte boundary
            XCTAssertEqual(RarVM.readData(&input), value, bits)
            XCTAssertEqual(input.bitPosition, consumed + 1, bits)
        }
        // Past the end the input yields zeros, as UnRAR's buffer does.
        var empty = VMBitInput([])
        XCTAssertEqual(RarVM.readData(&empty), 0)
    }

    func pack(_ bits: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var current: UInt8 = 0
        for (index, bit) in bits.enumerated() {
            current = current << 1 | (bit == "1" ? 1 : 0)
            if index % 8 == 7 {
                bytes.append(current)
                current = 0
            }
        }
        if bits.count % 8 != 0 { bytes.append(current << UInt8(8 - bits.count % 8)) }
        return bytes
    }

    func testRecognise() {
        XCTAssertEqual(RarVM.recognise([]), .badChecksum)
        XCTAssertEqual(RarVM.recognise([0x01, 0x02]), .badChecksum)
        XCTAssertEqual(RarVM.recognise([0x03, 0x01, 0x02]), .unknown)
    }

    // MARK: - Filters

    func memory(_ rng: inout some RandomNumberGenerator, fill: UInt8? = nil) -> [UInt8] {
        (0..<(RarVM.memorySize + 4)).map { _ in fill ?? UInt8.random(in: 0...255, using: &rng) }
    }

    func registers(_ values: [Int: UInt32]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: 7)
        for (index, value) in values { result[index] = value }
        return result
    }

    /// Parameters UnRAR rejects leave the data unchanged.
    func testInvalidParametersLeaveDataUnchanged() {
        var rng = SystemRandomNumberGenerator()
        let size = UInt32(RarVM.memorySize)
        let invalid: [(StandardFilter, [Int: UInt32])] = [
            (.e8, [4: size + 1]), (.e8, [4: 3]),
            (.e8e9, [4: size + 1]),
            (.itanium, [4: size + 1]), (.itanium, [4: 20]),
            (.delta, [4: size / 2 + 1, 0: 1]), (.delta, [4: 100, 0: 0]), (.delta, [4: 100, 0: 1025]),
            (.rgb, [4: size / 2 + 1, 0: 6]), (.rgb, [4: 2, 0: 3]), (.rgb, [4: 100, 0: 2]),
            (.rgb, [4: 100, 0: 104]), (.rgb, [4: 100, 0: 6, 1: 3]),
            (.audio, [4: size / 2 + 1, 0: 1]), (.audio, [4: 100, 0: 0]), (.audio, [4: 100, 0: 129]),
        ]
        for (filter, values) in invalid {
            let original = memory(&rng)
            var data = original
            XCTAssertFalse(RarVM.apply(filter, registers: registers(values), memory: &data), "\(filter) \(values)")
            XCTAssertEqual(data, original, "\(filter) \(values)")
            let result = RarVM.execute(filter, registers: registers(values), memory: &data)
            XCTAssertEqual(result.offset, 0, "\(filter) \(values)")
        }
    }

    /// The largest valid parameters stay inside VM memory.
    func testLargestValidParametersDoNotTrap() {
        var rng = SystemRandomNumberGenerator()
        let size = UInt32(RarVM.memorySize)
        let extremes: [(StandardFilter, [Int: UInt32], UInt8?)] = [
            (.e8, [4: size, 6: .max], 0xE8),
            (.e8e9, [4: size, 6: .max], 0xE9),
            (.itanium, [4: size, 6: .max], 0x10),
            (.itanium, [4: size, 6: .max], nil),
            (.delta, [4: size / 2, 0: 1024], nil),
            (.delta, [4: size / 2, 0: 1], nil),
            (.rgb, [4: size / 2, 0: size / 2 + 3, 1: 2], nil),
            (.rgb, [4: size / 2, 0: 3, 1: 0], nil),
            (.rgb, [4: 3, 0: 3, 1: 2], nil),
            (.audio, [4: size / 2, 0: 128], nil),
            (.audio, [4: size / 2, 0: 1], nil),
        ]
        for (filter, values, fill) in extremes {
            var data = memory(&rng, fill: fill)
            XCTAssertTrue(RarVM.apply(filter, registers: registers(values), memory: &data), "\(filter) \(values)")
            XCTAssertEqual(data.count, RarVM.memorySize + 4)
        }
    }

    /// Both address conversions of the E8 filter, worked out by hand from
    /// UnRAR's rule: a negative address that lands at or after 0 gains the
    /// 16 MiB file size; an address below it loses the offset.
    func testE8ConvertsBothAddressKinds() {
        var data = [UInt8](repeating: 0, count: RarVM.memorySize + 4)
        // Opcode at 0: offset = 1 + fileOffset (2) = 3; address -1 -> 0x00FFFFFF.
        data[0] = 0xE8
        data[1...4] = [0xFF, 0xFF, 0xFF, 0xFF]
        // Opcode at 5: offset = 6 + 2 = 8; address 0x20 -> 0x18.
        data[5] = 0xE8
        data[6...9] = [0x20, 0, 0, 0]
        // Opcode at 10: address -100 with offset 13 stays negative: unchanged.
        data[10] = 0xE8
        data[11...14] = [0x9C, 0xFF, 0xFF, 0xFF]
        XCTAssertTrue(RarVM.apply(.e8, registers: registers([4: 32, 6: 2]), memory: &data))
        XCTAssertEqual(Array(data[0..<15]), [0xE8, 0xFF, 0xFF, 0xFF, 0x00,
                                             0xE8, 0x18, 0, 0, 0,
                                             0xE8, 0x9C, 0xFF, 0xFF, 0xFF])
    }

    /// No fixture covers E8E9, so it is checked against E8 (which the
    /// `rar4-flt-e8` fixture covers): without 0xE9 bytes both are the same,
    /// and E8E9 treats 0xE9 exactly as it treats 0xE8.
    func testE8E9AgreesWithE8() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let count = Int.random(in: 64...4096, using: &rng)
            var plain = memory(&rng)
            for index in 0..<count where plain[index] == 0xE9 { plain[index] = 0 }
            plain[0] = 0xE8 // at least one opcode
            for _ in 0..<(count / 16) { plain[Int.random(in: 0..<count, using: &rng)] = 0xE8 }
            let values = registers([4: UInt32(count), 6: UInt32.random(in: 0...UInt32.max, using: &rng)])

            var e8 = plain
            var e8e9 = plain
            XCTAssertTrue(RarVM.apply(.e8, registers: values, memory: &e8))
            XCTAssertTrue(RarVM.apply(.e8e9, registers: values, memory: &e8e9))
            XCTAssertEqual(e8, e8e9)

            // Turn the opcodes E8 found into 0xE9: E8E9 must convert the
            // same addresses and leave the opcodes as they are.
            let opcodes = opcodePositions(plain, count)
            XCTAssertFalse(opcodes.isEmpty)
            var swapped = plain
            var expected = e8
            for index in opcodes {
                swapped[index] = 0xE9
                expected[index] = 0xE9
            }
            XCTAssertTrue(RarVM.apply(.e8e9, registers: values, memory: &swapped))
            XCTAssertEqual(swapped, expected)
        }
    }

    /// The opcode positions in E8's left-to-right scan.
    func opcodePositions(_ data: [UInt8], _ count: Int) -> [Int] {
        var positions: [Int] = []
        var position = 0
        while position < count - 4 {
            if data[position] == 0xE8 {
                positions.append(position)
                position += 5
            } else {
                position += 1
            }
        }
        return positions
    }

    /// No fixture covers Itanium: check the bit surgery against a bundle
    /// built by hand. Template 0x10 patches slot 2 only (mask 4); with
    /// opcode 5 there, the 20-bit field at bit 5 + 2 * 41 + 13 becomes
    /// `field - fileOffset >> 4`.
    func testItaniumPatchesBranchTarget() {
        var data = [UInt8](repeating: 0, count: RarVM.memorySize + 4)
        data[0] = 0x10
        let start = 5 + 2 * 41
        setBits(&data, 5, at: start + 37, count: 4)
        setBits(&data, 0x12345, at: start + 13, count: 20)
        let snapshot = data
        let values = registers([4: 32, 6: 0x30])
        XCTAssertTrue(RarVM.apply(.itanium, registers: values, memory: &data))
        XCTAssertEqual(bits(data, at: start + 13, count: 20), 0x12345 - 3)
        XCTAssertEqual(bits(data, at: start + 37, count: 4), 5)
        // Only the target field changed.
        var expected = snapshot
        setBits(&expected, 0x12345 - 3, at: start + 13, count: 20)
        XCTAssertEqual(data, expected)
        // Other opcodes are left alone.
        var other = snapshot
        setBits(&other, 4, at: start + 37, count: 4)
        let untouched = other
        XCTAssertTrue(RarVM.apply(.itanium, registers: values, memory: &other))
        XCTAssertEqual(other, untouched)
    }

    func setBits(_ data: inout [UInt8], _ value: UInt32, at position: Int, count: Int) {
        for bit in 0..<count {
            let index = (position + bit) / 8
            let mask = UInt8(1 << ((position + bit) % 8))
            if value >> UInt32(bit) & 1 == 1 { data[index] |= mask } else { data[index] &= ~mask }
        }
    }

    func bits(_ data: [UInt8], at position: Int, count: Int) -> UInt32 {
        (0..<count).reduce(UInt32(0)) { value, bit in
            let index = (position + bit) / 8
            return value | UInt32(data[index] >> UInt8((position + bit) % 8) & 1) << UInt32(bit)
        }
    }
}
