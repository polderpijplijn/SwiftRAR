// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import SwiftRAR

/// `RARReader`: listing and extracting single entries without a ZIP (phase 8).
final class ReaderTests: XCTestCase {
    let fixtures = PPMdTests()

    func reader(_ name: String) throws -> RARReader {
        let limits = FixtureTests.limitOverrides[name] ?? .default
        return try RARReader(source: DataSource(try fixtures.fixture(name)), limits: limits)
    }

    /// Every regular file `unrar x` extracts, by relative path (NFC).
    func oracle(_ name: String) throws -> [String: [UInt8]] {
        let unrar = try Tools.requireUnrar()
        let directory = try makeTemporaryDirectory(self)
        let input = Tools.fixturesDirectory.appendingPathComponent("\(name).rar")
        let result = try Tools.run(unrar, ["x", "-y", "-idq", input.path, directory.path + "/"])
        XCTAssertEqual(result.status, 0, "unrar: \(result.output)")
        return try readTree(directory)
    }

    func shuffled(_ entries: [RARReader.Entry], seed: UInt64) -> [RARReader.Entry] {
        var generator = SeededGenerator(seed: seed)
        return entries.shuffled(using: &generator)
    }

    // MARK: - Oracle

    /// Large solid PPMd fixtures, left out: backwards is one pass per entry,
    /// minutes in a debug build, and `FixtureTests` already decodes them
    /// forwards with the same session code. `rar4-mct-s` covers solid PPMd
    /// in every order here.
    static let slow: Set<String> = ["rar4-mct-flt", "rar4-mct-mix", "rar4-mct-mem"]

    /// Every supported fixture, read forwards, backwards and shuffled with
    /// one reader, matches unrar byte for byte.
    func testEveryEntryMatchesTheOracleInAnyOrder() throws {
        for name in FixtureTests.supported.subtracting(Self.slow).sorted() {
            let expected = try oracle(name)
            let reader = try reader(name)
            XCTAssertEqual(Set(reader.entries.map { $0.name.precomposedStringWithCanonicalMapping }),
                           Set(expected.keys), name)
            let orders = [reader.entries, reader.entries.reversed(), shuffled(reader.entries, seed: 7)]
            for (number, order) in orders.enumerated() {
                for entry in order {
                    let data = try reader.data(for: entry)
                    XCTAssertTrue([UInt8](data) == expected[entry.name.precomposedStringWithCanonicalMapping],
                                  "\(name) order \(number): \(entry.name) differs from oracle")
                }
            }
        }
    }

    // MARK: - Random access and solid streams

    /// Non-solid: every compressed entry is decoded on its own, stored
    /// entries not at all.
    func testNonSolidReadsOnlyTheRequestedEntry() throws {
        for name in ["rar4-m3", "rar5-m3", "rar4-m3-flt", "rar4-mct"] {
            let reader = try reader(name)
            XCTAssertFalse(reader.isSolid)
            for entry in reader.entries.reversed() {
                let before = reader.decodedEntries
                _ = try reader.data(for: entry)
                XCTAssertEqual(reader.decodedEntries - before, entry.isCompressed ? 1 : 0, "\(name): \(entry.name)")
            }
        }
    }

    /// Solid, in archive order: one pass, each entry decoded once.
    func testSolidInOrderDecodesEachEntryOnce() throws {
        for name in ["rar4-s", "rar5-s", "rar4-mct-s", "rar4-s-flt", "rar5-s-flt", "rar4-s2", "rar5-s2"] {
            let reader = try reader(name)
            XCTAssertTrue(reader.isSolid, name)
            for entry in reader.entries { _ = try reader.data(for: entry) }
            XCTAssertEqual(reader.decodedEntries, reader.entries.filter(\.isCompressed).count, name)
        }
    }

    /// One solid stream: the last entry needs every compressed entry before it.
    func testSolidLastEntryFirstDecodesTheWholeStream() throws {
        for name in ["rar4-s", "rar5-s"] {
            let reader = try reader(name)
            _ = try reader.data(for: try XCTUnwrap(reader.entries.last))
            XCTAssertEqual(reader.decodedEntries, reader.entries.filter(\.isCompressed).count, name)
        }
    }

    /// `-s2` starts a new stream every two files: going backwards never
    /// decodes more than one group.
    func testSolidGroupsRestartAtTheirOwnStart() throws {
        for name in ["rar4-s2", "rar5-s2"] {
            let reader = try reader(name)
            for entry in reader.entries.reversed() {
                let before = reader.decodedEntries
                _ = try reader.data(for: entry)
                XCTAssertLessThanOrEqual(reader.decodedEntries - before, 2, "\(name): \(entry.name)")
            }
            // Six files in groups of two: page01+02, page03+empty, unicode+ComicInfo.
            XCTAssertEqual(reader.entries.count, 6, name)
        }
    }

    // MARK: - Validation

    /// The reader refuses exactly what conversion refuses, with the same error.
    func testOpenFailsLikeConversion() throws {
        var small = Limits.default
        small.maxEntrySize = 1_000
        let cases: [(String, [UInt8], Limits)] = [
            ("encrypted", RAR4Builder.build([TestFile(name: "a", contents: [1], encrypted: true)]), .default),
            ("split", RAR5Builder.build([TestFile(name: "a", contents: [1], split: true)]), .default),
            ("method", RAR4Builder.build([TestFile(name: "a", contents: [1, 2], method: 3, unpackVersion: 20)]), .default),
            ("duplicate", RAR4Builder.build([TestFile(name: "a/b.jpg", contents: [1]),
                                             TestFile(name: "a\\b.jpg", contents: [2])]), .default),
            ("entry size", RAR5Builder.build(sampleFiles()), small),
            ("empty", RAR4Builder.build([TestFile(name: "d", contents: [], isDirectory: true)]), .default),
        ]
        for (label, bytes, limits) in cases {
            var conversionError: RARError?
            XCTAssertThrowsError(try convertToCBZ(source: DataSource(bytes), output: MemoryOutput(), limits: limits)) {
                conversionError = $0 as? RARError
            }
            XCTAssertThrowsError(try RARReader(source: DataSource(bytes), limits: limits), label) {
                XCTAssertEqual($0 as? RARError, conversionError, label)
            }
            XCTAssertNotNil(conversionError, label)
        }
    }

    func testEntryOfAnotherReaderIsRejected() throws {
        let first = try reader("rar4-m3")
        let second = try RARReader(source: DataSource(RAR4Builder.build(sampleFiles())), limits: .default)
        let foreign = try XCTUnwrap(second.entries.first)
        XCTAssertThrowsError(try first.data(for: foreign)) {
            XCTAssertEqual($0 as? RARError, .invalidEntryName(foreign.name))
        }
    }

    // MARK: - Failures

    /// A damaged entry fails; the reader recovers for every other entry,
    /// in the damaged entry's own group as well as in others.
    func testCorruptEntryDoesNotPoisonTheReader() throws {
        let name = "rar4-s2"
        let expected = try oracle(name)
        var bytes = try fixtures.fixture(name)
        let archive = try RARArchive(source: DataSource(bytes), limits: .default)
        // page03.jpg starts the second group; flip a byte in the middle of its data.
        let damaged = try XCTUnwrap(archive.entries.first { $0.rawName.hasSuffix("page03.jpg") })
        bytes[Int(damaged.dataOffset + damaged.packedSize / 2)] ^= 0x55
        let reader = try RARReader(source: DataSource(bytes), limits: .default)
        let byName = Dictionary(uniqueKeysWithValues: reader.entries.map { ($0.name, $0) })
        func check(_ entryName: String) throws {
            let data = try reader.data(for: try XCTUnwrap(byName[entryName]))
            XCTAssertTrue([UInt8](data) == expected[entryName.precomposedStringWithCanonicalMapping], entryName)
        }

        try check("book/pages/page01.jpg")
        XCTAssertThrowsError(try reader.data(for: try XCTUnwrap(byName["book/pages/page03.jpg"])))
        // The next entry of that group now restarts at page03 and fails too:
        // its stream is damaged.
        XCTAssertThrowsError(try reader.data(for: try XCTUnwrap(byName["book/pages/empty.txt"])))
        try check("book/pages/page02.jpg")
        try check("book/ComicInfo.xml")
        try check("book/pages/page01.jpg")
    }

    /// A page load cancelled halfway leaves a reader that reads that page
    /// in a later task.
    func testCancelledExtractionDoesNotPoisonTheReader() async throws {
        let name = "rar4-s"
        let expected = try oracle(name)
        let bytes = try fixtures.fixture(name)
        let archive = try RARArchive(source: DataSource(bytes), limits: .default)
        let target = try XCTUnwrap(archive.entries.first { $0.rawName.hasSuffix("page03.jpg") })
        let box = ReaderBox(try RARReader(source: CancellingSource(DataSource(bytes), cancelAt: target.dataOffset),
                                          limits: .default))
        let entry = try XCTUnwrap(box.reader.entries.first { $0.name == "book/pages/page03.jpg" })

        let first = await Task.detached { () -> RARError? in
            do {
                _ = try box.reader.data(for: entry)
                return nil
            } catch {
                return error as? RARError
            }
        }.value
        XCTAssertEqual(first, .cancelled)

        let decodedBefore = box.reader.decodedEntries
        let second = try await Task.detached { try box.reader.data(for: entry) }.value
        XCTAssertTrue([UInt8](second) == expected["book/pages/page03.jpg"])
        XCTAssertEqual(box.reader.decodedEntries - decodedBefore, 3, "restarts at the start of the stream")
    }

    /// Truncations and mutations only ever throw `RARError`, through the
    /// reader as through conversion.
    func testRobustness() {
        var limits = Limits.default
        limits.maxEntrySize = 1 << 20
        func exercise(_ bytes: [UInt8]) {
            do {
                let reader = try RARReader(source: DataSource(bytes), limits: limits)
                for entry in reader.entries.reversed() { _ = try? reader.data(for: entry) }
            } catch {
                XCTAssertTrue(error is RARError, "\(error)")
            }
        }
        var generator = SeededGenerator(seed: 43)
        for archive in RobustnessTests().archives() {
            for length in 0..<archive.count { exercise(Array(archive.prefix(length))) }
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

/// Hands one reader to consecutive tasks. Never used by two at once.
private final class ReaderBox: @unchecked Sendable {
    let reader: RARReader
    init(_ reader: RARReader) { self.reader = reader }
}
