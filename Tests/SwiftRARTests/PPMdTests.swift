// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import RARCore
@testable import RARDecode
import SwiftRAR

/// PPMd variant H in RAR4 `-mct` blocks (phase 4).
final class PPMdTests: XCTestCase {
    func fixture(_ name: String) throws -> [UInt8] {
        let url = Tools.fixturesDirectory.appendingPathComponent("\(name).rar")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Tools.unavailable("fixture \(name) missing") }
        return [UInt8](try Data(contentsOf: url))
    }

    /// Decodes every compressed entry in archive order with one session.
    @discardableResult
    func decodeAll(_ bytes: [UInt8], limits: Limits = .default) throws -> RARDecoder.Session {
        let source = DataSource(bytes)
        let archive = try RARArchive(source: source, limits: limits)
        let session = RARDecoder.Session(limits: limits)
        for entry in archive.entries where !entry.isStored && !entry.isDirectory {
            try session.decode(entry, from: source) { _ in }
        }
        return session
    }

    // MARK: - Fixtures

    /// A fixture that rar packed differently would test nothing, so each one
    /// must go through the PPMd paths it is meant for. RAR 6.24 never
    /// registers a filter inside a PPMd block (escape 3), so escape 3 has no
    /// fixture. A solid entry that follows PPMd always starts with a new
    /// PPMd header, as in UnRAR (see the issue #8 test below).
    func testFixturesTakeTheirPPMdPaths() throws {
        let plain = try decodeAll(fixture("rar4-mct")).ppmdCoverage
        XCTAssertGreaterThan(plain.resets, 0)
        XCTAssertGreaterThan(plain.escapes[2, default: 0], 0, "end of file in PPMd")

        // Solid entries continue the model with a header without reset.
        let solid = try decodeAll(fixture("rar4-mct-s")).ppmdCoverage
        XCTAssertGreaterThan(solid.continuations, 0)

        // rar switches from PPMd to LZ inside an entry, and filters the LZ part.
        let mixed = try decodeAll(fixture("rar4-mct-mix"))
        XCTAssertGreaterThan(mixed.ppmdCoverage.escapes[0, default: 0], 0, "PPMd to LZ")
        XCTAssertGreaterThan(mixed.ppmdCoverage.escapes[1, default: 0], 0, "literal escape byte")
        XCTAssertGreaterThan(mixed.ppmdCoverage.continuations, 0)
        XCTAssertFalse(mixed.appliedFilters.isEmpty)

        // PPMd over random data, next to LZ with the audio filter.
        let binary = try decodeAll(fixture("rar4-mct-flt"))
        XCTAssertGreaterThan(binary.ppmdCoverage.escapes[1, default: 0], 0)
        XCTAssertNotNil(binary.appliedFilters[.audio])

        // Repeats and runs: LZ matches and RLE inside PPMd.
        let repeats = try decodeAll(fixture("rar4-mct-rep")).ppmdCoverage
        XCTAssertGreaterThan(repeats.escapes[4, default: 0], 0, "match inside PPMd")
        XCTAssertGreaterThan(repeats.escapes[5, default: 0], 0, "RLE inside PPMd")
    }

    /// Maximum order in 1 MiB: the model runs out of memory and restarts,
    /// and the allocator glues free blocks and takes units from the text area.
    func testMemoryStarvedModelRestarts() throws {
        let coverage = try decodeAll(fixture("rar4-mct-mem")).ppmdCoverage
        XCTAssertGreaterThan(coverage.restarts, 0)
        XCTAssertGreaterThan(coverage.glueRuns, 0)
        XCTAssertGreaterThan(coverage.textAreaAllocations, 0)
        XCTAssertGreaterThan(coverage.rescales, 0)
    }

    /// Issue #8: entry 1 goes from LZ to PPMd through end of block "1",
    /// which clears TablesRead3 in UnRAR, so the solid entry 2 starts with
    /// a new PPMd header, which restarts the model. Skipping that header
    /// decoded garbage.
    func testSolidEntryAfterLZToPPMdReadsNewHeader() throws {
        let url = Tools.repositoryRoot.appendingPathComponent("Fuzz/seeds/seed-rar4-mct-solid.rar")
        let session = try decodeAll([UInt8](try Data(contentsOf: url)))
        XCTAssertEqual(session.ppmdCoverage.resets, 2, "one PPMd header per entry")
        XCTAssertEqual(session.ppmdCoverage.continuations, 0)
    }

    // MARK: - Limits and headers

    /// `rar4-mct` asks for 15 MiB of model memory.
    func testMemoryLimit() throws {
        let bytes = try fixture("rar4-mct")
        var limits = Limits.default
        limits.maxPPMdMemory = 14 << 20
        XCTAssertThrowsError(try decodeAll(bytes, limits: limits)) {
            XCTAssertEqual($0 as? RARError, .limitExceeded(.ppmdMemory))
        }
        limits.maxPPMdMemory = 15 << 20
        XCTAssertNoThrow(try decodeAll(bytes, limits: limits))
    }

    /// One hand-built compressed entry whose data is `packed`.
    func decodeHandBuilt(_ packed: [UInt8], limits: Limits = .default) throws {
        let bytes = RAR4Builder.build([TestFile(name: "a.txt", contents: packed, method: 3)])
        let source = DataSource(bytes)
        let archive = try RARArchive(source: source, limits: limits)
        let entry = try XCTUnwrap(archive.entries.first)
        try RARDecoder.decode(entry, from: source, limits: limits) { _ in }
    }

    /// `Limits.constrained` allows 64 MiB of model memory, not 65.
    func testConstrainedMemoryLimit() {
        // Reset, order 4, 65 MiB.
        XCTAssertThrowsError(try decodeHandBuilt([0xA3, 0x40, 0, 0, 0, 0, 0, 0], limits: .constrained)) {
            XCTAssertEqual($0 as? RARError, .limitExceeded(.ppmdMemory))
        }
        // 64 MiB passes the limit; the made-up data then fails elsewhere.
        XCTAssertThrowsError(try decodeHandBuilt([0xA3, 0x3F, 0, 0, 0, 0, 0, 0], limits: .constrained)) {
            XCTAssertNotEqual($0 as? RARError, .limitExceeded(.ppmdMemory))
        }
    }

    func testHeaderAskingForTooMuchMemoryThrowsBeforeAllocating() {
        var limits = Limits.default
        limits.maxPPMdMemory = 16 << 20
        // Reset, order 4, 256 MiB.
        XCTAssertThrowsError(try decodeHandBuilt([0xA3, 0xFF, 0, 0, 0, 0, 0, 0], limits: limits)) {
            XCTAssertEqual($0 as? RARError, .limitExceeded(.ppmdMemory))
        }
    }

    func testOrderOneIsRejected() {
        // Reset, order 1, 1 MiB.
        XCTAssertThrowsError(try decodeHandBuilt([0xA0, 0x00, 0, 0, 0, 0, 0, 0])) {
            XCTAssertEqual($0 as? RARError, .corruptData("PPMd order 1"))
        }
    }

    /// A non-solid entry never continues another entry's model.
    func testBlockWithoutResetNeedsAModel() {
        XCTAssertThrowsError(try decodeHandBuilt([0x83, 0, 0, 0, 0, 0, 0, 0])) {
            XCTAssertEqual($0 as? RARError, .corruptData("PPMd block continues a model that does not exist"))
        }
    }

    // MARK: - Corruption

    func testCorruptedPPMdDataNeverTraps() throws {
        var rng = SystemRandomNumberGenerator()
        // rar4-mct-flt and rar4-mct-mem take seconds per decode in debug; the
        // fuzzer covers them.
        for name in ["rar4-mct", "rar4-mct-s", "rar4-mct-mix", "rar4-mct-rep"] {
            let bytes = try fixture(name)
            let archive = try RARArchive(source: DataSource(bytes), limits: .default)
            let compressed = archive.entries.filter { !$0.isStored && !$0.isDirectory && $0.packedSize > 8 }
            for round in 0..<6 {
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
            try decodeAll(bytes)
        } catch is RARError {
        } catch {
            XCTFail("\(label): non-RARError \(error)")
        }
        // The largest of these fixtures decodes in about 12 s in debug.
        XCTAssertLessThan(Date().timeIntervalSince(start), 60, label)
    }

    // MARK: - Byte input

    func testReadByteYieldsZerosPastTheEndUpToTheCap() throws {
        var reader = try StreamBitReader(source: DataSource([0xAB, 0xCD]), offset: 0, count: 2)
        XCTAssertEqual(try reader.readByte(), 0xAB)
        XCTAssertEqual(try reader.readByte(), 0xCD)
        XCTAssertEqual(reader.overreadBytes, 0)
        for _ in 0..<StreamBitReader.maxOverread {
            XCTAssertEqual(try reader.readByte(), 0)
        }
        XCTAssertEqual(reader.overreadBytes, StreamBitReader.maxOverread)
        XCTAssertThrowsError(try reader.readByte()) {
            XCTAssertEqual($0 as? RARError, .truncated)
        }
    }

    // MARK: - Suballocator

    /// Issue #9B: eight input bytes can reset the model at a different size
    /// without producing output. These fixed blocks decode escape 0 with
    /// escape character 0; the last block decodes escape 2 (end of file).
    func testAlternatingMemoryBlocks() throws {
        var packed: [UInt8] = []
        let blocks = 128
        for index in 0..<blocks {
            packed += [0xE3, index.isMultiple(of: 2) ? 0xFF : 0xFE, 0, 0, 0, 0, 0, 0]
        }
        packed += [0xE3, 0xFE, 0, 0, 5, 0xDC, 0xB6, 0x64, 0]
        let archive = RAR4Builder.build([
            TestFile(name: "empty", contents: packed, crcOverride: 0,
                     unpackedSizeOverride: 0, method: 3)
        ])
        let seed = Tools.repositoryRoot.appendingPathComponent("Fuzz/seeds/seed-rar4-mct-resize.rar")
        XCTAssertEqual(archive, [UInt8](try Data(contentsOf: seed)))
        let start = Date()
        let coverage = try decodeAll(archive).ppmdCoverage
        print("PPMd alternating memory: \(packed.count) packed bytes, \(blocks + 1) resets, \(Date().timeIntervalSince(start)) s")
        XCTAssertEqual(coverage.resets, blocks + 1)
        XCTAssertEqual(coverage.escapes[0], blocks)
        XCTAssertEqual(coverage.escapes[2], 1)
    }

    /// After a large model, real data must decode in the smaller active
    /// heap, including allocator exhaustion, glueing and model restarts.
    func testFixturesAfterHeapShrinks() throws {
        for name in ["rar4-mct", "rar4-mct-mem"] {
            let bytes = try fixture(name)
            let archive = try RARArchive(source: DataSource(bytes), limits: .default)
            var entry = try XCTUnwrap(archive.entries.first { !$0.isStored && !$0.isDirectory })
            let start = Int(entry.dataOffset)
            // Escape 0 with the default escape character 2, so the fixture
            // keeps its original escape character when its header omits it.
            let packed = [UInt8]([0xA3, 0xFF, 1, 0xFE, 1, 0xFE, 0, 0])
                + Array(bytes[start..<(start + Int(entry.packedSize))])
            // Preserve the original dictionary size as well as output size
            // and CRC: these PPMd streams can also contain LZ matches.
            entry.dataOffset = 0
            entry.packedSize = UInt64(packed.count)
            let session = RARDecoder.Session(limits: .default)
            try session.decode(entry, from: DataSource(packed)) { _ in }
            let coverage = session.ppmdCoverage
            XCTAssertGreaterThanOrEqual(coverage.resets, 2)
            XCTAssertGreaterThanOrEqual(coverage.escapes[0, default: 0], 1)
            if name == "rar4-mct-mem" {
                XCTAssertGreaterThan(coverage.restarts, 0)
                XCTAssertGreaterThan(coverage.glueRuns, 0)
                XCTAssertGreaterThan(coverage.textAreaAllocations, 0)
            }
        }
    }

    func testHeapReusesLargerBuffer() throws {
        var heap = PPMdHeap()
        heap.start(megabytes: 2)
        let capacity = heap.bytes.count
        try heap.setByte(PPMdHeap.base, 0xA5)
        for megabytes in [1, 2, 1, 2] {
            heap.start(megabytes: megabytes)
            heap.reset()
            XCTAssertEqual(heap.bytes.count, capacity)
            XCTAssertEqual(try heap.byte(PPMdHeap.base), 0xA5, "start must not zero the reused buffer")
            XCTAssertEqual(heap.allocatorSize, megabytes << 20)
        }
        heap.start(megabytes: 3)
        XCTAssertGreaterThan(heap.bytes.count, capacity)
        heap.stop()
        XCTAssertTrue(heap.bytes.isEmpty)
        XCTAssertEqual(heap.allocatorSize, 0)
        XCTAssertEqual(heap.heapEnd, 0)
    }

    func testShrunkHeapChecksActiveBounds() throws {
        var heap = PPMdHeap()
        heap.start(megabytes: 2)
        heap.start(megabytes: 1)
        heap.reset()
        let end = heap.heapEnd + PPMdHeap.unitSize
        XCTAssertGreaterThan(heap.bytes.count, end)
        try heap.setByte(end - 1, 0xA5)
        XCTAssertEqual(try heap.byte(end - 1), 0xA5)
        try heap.setU16(end - 2, 0x1234)
        XCTAssertEqual(try heap.u16(end - 2), 0x1234)
        try heap.setU32(end - 4, 0x12345678)
        XCTAssertEqual(try heap.u32(end - 4), 0x12345678)
        try heap.copyBytes(from: end - 4, to: PPMdHeap.base, count: 4)
        try heap.copyBytes(from: PPMdHeap.base, to: end - 4, count: 4)
        XCTAssertThrowsError(try heap.byte(end))
        XCTAssertThrowsError(try heap.setByte(end, 0))
        XCTAssertThrowsError(try heap.u16(end - 1))
        XCTAssertThrowsError(try heap.setU16(end - 1, 0))
        XCTAssertThrowsError(try heap.u32(end - 3))
        XCTAssertThrowsError(try heap.setU32(end - 3, 0))
        XCTAssertThrowsError(try heap.copyBytes(from: end - 3, to: PPMdHeap.base, count: 4))
        XCTAssertThrowsError(try heap.copyBytes(from: PPMdHeap.base, to: end - 3, count: 4))
        heap.stop()
        XCTAssertThrowsError(try heap.byte(PPMdHeap.base))
        XCTAssertThrowsError(try heap.setByte(PPMdHeap.base, 0))
    }

    /// Random allocations, expansions, shrinks and frees, in a heap small
    /// enough that glueing and the text-area path both run. Every live block
    /// carries a pattern; no block may overlap another or lose its pattern.
    func testSuballocatorKeepsLiveBlocksIntact() throws {
        var heap = PPMdHeap()
        heap.start(megabytes: 1)
        heap.reset()
        var rng = SeededGenerator(seed: 7)
        var live: [(offset: Int, units: Int, tag: UInt8)] = []
        var tag: UInt8 = 0

        func fill(_ offset: Int, _ units: Int, _ value: UInt8) throws {
            for index in 0..<(units * PPMdHeap.unitSize) { try heap.setByte(offset + index, Int(value)) }
        }
        func check(_ block: (offset: Int, units: Int, tag: UInt8)) throws {
            for index in 0..<(block.units * PPMdHeap.unitSize) {
                XCTAssertEqual(try heap.byte(block.offset + index), Int(block.tag), "block at \(block.offset)")
            }
        }

        var exhausted = 0
        for step in 0..<40_000 {
            tag &+= 1
            if tag == 0 { tag = 1 }
            let action = Int.random(in: 0..<20, using: &rng)
            if action < 14 || live.isEmpty {
                let units = Int.random(in: 1...(step.isMultiple(of: 50) ? 128 : 8), using: &rng)
                let offset = units == 1 && action == 0 ? try heap.allocContext() : try heap.allocUnits(units)
                if offset == 0 {
                    exhausted += 1
                    // Free half, as a model restart would free everything.
                    for block in live.prefix(live.count / 2) { try heap.freeUnits(block.offset, count: block.units) }
                    live.removeFirst(live.count / 2)
                    continue
                }
                try fill(offset, units, tag)
                live.append((offset, units, tag))
            } else if action < 17 {
                let index = Int.random(in: 0..<live.count, using: &rng)
                let block = live[index]
                guard block.units < 128 else { continue }
                let moved = try heap.expandUnits(block.offset, oldCount: block.units)
                guard moved != 0 else { continue }
                let grown = (moved, block.units + 1, tag)
                try fill(moved, grown.1, tag)
                live[index] = grown
            } else if action < 18 {
                let index = Int.random(in: 0..<live.count, using: &rng)
                let block = live[index]
                let newUnits = Int.random(in: 1...block.units, using: &rng)
                let moved = try heap.shrinkUnits(block.offset, oldCount: block.units, newCount: newUnits)
                try fill(moved, newUnits, tag)
                live[index] = (moved, newUnits, tag)
            } else {
                let block = live.remove(at: Int.random(in: 0..<live.count, using: &rng))
                try heap.freeUnits(block.offset, count: block.units)
            }
            if step.isMultiple(of: 2_000) {
                for block in live { try check(block) }
                let sorted = live.sorted { $0.offset < $1.offset }
                for (a, b) in zip(sorted, sorted.dropFirst()) {
                    XCTAssertLessThanOrEqual(a.offset + a.units * PPMdHeap.unitSize, b.offset, "overlap")
                }
                for block in sorted {
                    XCTAssertGreaterThan(block.offset, heap.pText)
                    XCTAssertLessThanOrEqual(block.offset + block.units * PPMdHeap.unitSize, heap.heapEnd)
                }
            }
        }
        for block in live { try check(block) }
        XCTAssertGreaterThan(exhausted, 0, "the heap never ran full")
        XCTAssertGreaterThan(heap.glueRuns, 0)
        XCTAssertGreaterThan(heap.textAreaAllocations, 0)
    }
}
