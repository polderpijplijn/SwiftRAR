// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import RARCore
@testable import RARDecode
@testable import SwiftRAR

/// Resource bounds from the review before the Grim Reader integration
/// (issue #2, docs/review-hardening-plan.md).
final class HardeningTests: XCTestCase {
    let fixtures = PPMdTests()

    func assertParseThrows(_ bytes: [UInt8], _ expected: RARError, limits: Limits = .default,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RARArchive(source: DataSource(bytes), limits: limits), file: file, line: line) {
            XCTAssertEqual($0 as? RARError, expected, file: file, line: line)
        }
    }

    // MARK: - 1. Names are checked while parsing

    /// The parser used to keep every name and leave the check to
    /// `planExtraction`; 10,000 RAR4 names of 64 KB is 650 MB.
    func testOverlongNameIsRejectedWhileParsing() {
        let name = String(repeating: "a", count: Limits.default.maxNameLength + 1)
        let files = [TestFile(name: name, contents: [1, 2, 3])]
        assertParseThrows(RAR4Builder.build(files), .limitExceeded(.nameLength))
        assertParseThrows(RAR5Builder.build(files), .limitExceeded(.nameLength))
    }

    func testNameOfExactlyTheLimitIsAccepted() throws {
        let name = String(repeating: "a", count: Limits.default.maxNameLength)
        let files = [TestFile(name: name, contents: [1, 2, 3])]
        for bytes in [RAR4Builder.build(files), RAR5Builder.build(files)] {
            let archive = try RARArchive(source: DataSource(bytes), limits: .default)
            XCTAssertEqual(archive.entries.first?.rawName, name)
        }
    }

    /// Service headers are skipped, but their names are read all the same.
    func testOverlongServiceNameIsRejected() {
        let name = String(repeating: "C", count: Limits.default.maxNameLength + 1)
        let files = [TestFile(name: name, contents: [], isService: true),
                     TestFile(name: "1.jpg", contents: [1, 2, 3])]
        assertParseThrows(RAR4Builder.build(files), .limitExceeded(.nameLength))
        assertParseThrows(RAR5Builder.build(files), .limitExceeded(.nameLength))
    }

    // MARK: - 2. Bound on all headers together

    /// Skipped service headers count too: they cost reads and time.
    func testHeaderBytesIncludeSkippedHeaders() {
        let services = (0..<200).map { TestFile(name: "CMT\($0)", contents: [], isService: true) }
        let files = services + [TestFile(name: "1.jpg", contents: [1, 2, 3])]
        var limits = Limits.default
        limits.maxHeaderBytes = 4_096
        assertParseThrows(RAR4Builder.build(files), .limitExceeded(.headerBytes), limits: limits)
        assertParseThrows(RAR5Builder.build(files), .limitExceeded(.headerBytes), limits: limits)
    }

    func testHeaderBytesWithinTheLimit() throws {
        let files = [TestFile(name: "1.jpg", contents: [1, 2, 3])]
        var limits = Limits.default
        limits.maxHeaderBytes = 256
        for bytes in [RAR4Builder.build(files), RAR5Builder.build(files)] {
            XCTAssertEqual(try RARArchive(source: DataSource(bytes), limits: limits).entries.count, 1)
        }
    }

    // MARK: - 3. Window no larger than the stream needs

    /// The review's case: three bytes of output in an entry that asks for a
    /// 256 MiB dictionary. Here the stream is valid, so the session keeps
    /// its state and the window can be measured.
    func testTinyRAR5EntryWithHugeDictionaryGetsASmallWindow() throws {
        var stream = RAR5Stream(extended: false)
        stream.literals([1, 2, 3])
        var file = TestFile(name: "p.jpg", contents: stream.bytes(), rar5Compression: 3 << 7 | 11 << 10)
        file.crcOverride = CRC32.checksum([1, 2, 3])
        let source = DataSource(RAR5Builder.build([file]))
        let archive = try RARArchive(source: source, limits: .default)
        var entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.dictionarySize, 256 << 20)
        entry.unpackedSize = 3

        let session = RARDecoder.Session(archive: archive, limits: .default)
        var output: [UInt8] = []
        try session.decode(entry, from: source) { output += $0 }
        XCTAssertEqual(output, [1, 2, 3])
        XCTAssertLessThanOrEqual(session.windowBytes, Unpack50.minimumWindow)
    }

    /// rar sizes the RAR4 dictionary to the data (`rar4-m3` says 256 KB),
    /// so the fixture is rewritten to ask for the 4 MiB maximum. The packed
    /// data does not depend on it.
    func testSmallRAR4EntriesGetASmallWindow() throws {
        let source = DataSource(Self.withRAR4Dictionary(try fixtures.fixture("rar4-m3"), bits: 6))
        let archive = try RARArchive(source: source, limits: .default)
        XCTAssertFalse(archive.isSolid)
        let session = RARDecoder.Session(archive: archive, limits: .default)
        var decoded = 0
        for entry in archive.entries where !entry.isStored && !entry.isDirectory {
            XCTAssertEqual(entry.dictionarySize, 4 << 20)
            try session.decode(entry, from: source) { _ in }
            var needed = Unpack29.minimumWindow
            while needed < Int(entry.unpackedSize + RARDecoder.Session.windowSlack) { needed <<= 1 }
            XCTAssertLessThan(needed, 4 << 20, "\(entry.rawName) proves nothing")
            XCTAssertLessThanOrEqual(session.windowBytes, needed, entry.rawName)
            decoded += 1
        }
        XCTAssertGreaterThan(decoded, 0)
    }

    /// Sets the dictionary bits of every RAR4 file header (directories
    /// excepted) and fixes the header CRCs.
    static func withRAR4Dictionary(_ bytes: [UInt8], bits: UInt16) -> [UInt8] {
        var out = bytes
        var position = 7
        while position + 7 <= out.count {
            let type = out[position + 2]
            var flags = UInt16(out[position + 3]) | UInt16(out[position + 4]) << 8
            let headSize = Int(out[position + 5]) | Int(out[position + 6]) << 8
            var dataSize = 0
            if type == 0x74 || flags & 0x8000 != 0 {
                dataSize = (0..<4).reduce(0) { $0 | Int(out[position + 7 + $1]) << (8 * $1) }
            }
            if type == 0x74, flags & 0x00E0 != 0x00E0 {
                flags = flags & ~0x00E0 | bits << 5
                out[position + 3] = UInt8(flags & 0xFF)
                out[position + 4] = UInt8(flags >> 8)
                let crc = UInt16(truncatingIfNeeded: CRC32.checksum(out[(position + 2)..<(position + headSize)]))
                out[position] = UInt8(crc & 0xFF)
                out[position + 1] = UInt8(crc >> 8)
            }
            if type == 0x7B { break }
            position += headSize + dataSize
        }
        return out
    }

    /// A solid stream gets a window for all of its data, so later entries
    /// still reach back into earlier ones.
    func testSolidArchivesStillDecodeWithTheStreamWindow() throws {
        for name in ["rar4-s", "rar5-s"] {
            let source = DataSource(try fixtures.fixture(name))
            var limits = Limits.default
            limits.maxCompressionRatio = 2_000
            let archive = try RARArchive(source: source, limits: limits)
            XCTAssertTrue(archive.isSolid, name)
            let session = RARDecoder.Session(archive: archive, limits: limits)
            for entry in archive.entries where !entry.isStored && !entry.isDirectory && !entry.isLink {
                XCTAssertNoThrow(try session.decode(entry, from: source) { _ in }, "\(name) \(entry.rawName)")
            }
        }
    }

    /// Follow-up review of fb64b49: a filter over the whole entry keeps it
    /// unflushed until the end. In a window of exactly the entry's size the
    /// position then wrapped onto the write position, full looked like
    /// empty, and the entry came out as `.truncated` with zero bytes.
    func testFilterOverTheWholeEntryFitsTheBoundedWindow() throws {
        let payload = [UInt8](repeating: 0, count: 300_000)
        var stream = RAR5Stream(extended: false)
        stream.filter(start: 0, length: payload.count, type: .arm) // zeros pass unchanged
        stream.literals(payload)
        var file = TestFile(name: "p.jpg", contents: stream.bytes(), rar5Compression: 3 << 7 | 2 << 10)
        file.unpackedSizeOverride = UInt64(payload.count)
        file.crcOverride = CRC32.checksum(payload)
        let bytes = RAR5Builder.build([file])

        let source = DataSource(bytes)
        let archive = try RARArchive(source: source, limits: .default)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.dictionarySize, 512 << 10)
        let session = RARDecoder.Session(archive: archive, limits: .default)
        var output: [UInt8] = []
        try session.decode(entry, from: source) { output += $0 }
        XCTAssertEqual(output, payload)
        XCTAssertLessThan(session.windowBytes, 512 << 10)

        let cbz = MemoryOutput()
        XCTAssertEqual(try convertToCBZ(source: DataSource(bytes), output: cbz, limits: .default).entryCount, 1)

        let unrar = try Tools.requireUnrar()
        let directory = try makeTemporaryDirectory(self)
        let archiveURL = directory.appendingPathComponent("filter.rar")
        try Data(bytes).write(to: archiveURL)
        XCTAssertEqual(try Tools.run(unrar, ["t", "-inul", archiveURL.path]).status, 0)
    }

    // MARK: - 4. ZIP passthrough

    /// A ZIP is copied, not validated, but never beyond the total limit.
    func testZIPPassthroughRespectsTheTotalLimit() {
        let bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 4_096)
        var limits = Limits.default
        limits.maxTotalSize = 1
        let output = MemoryOutput()
        XCTAssertThrowsError(try convertToCBZ(source: DataSource(bytes), output: output, limits: limits)) {
            XCTAssertEqual($0 as? RARError, .limitExceeded(.totalSize))
        }
        XCTAssertTrue(output.bytes.isEmpty)
    }

    // MARK: - 5. Cancellation

    func testCancelledConversionStopsAndLeavesNoFile() async throws {
        let bytes = try fixtures.fixture("rar5-m3-big")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftrar-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.cbr")
        let destination = directory.appendingPathComponent("out.cbz")
        try Data(bytes).write(to: source)

        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try convertToCBZ(from: source, to: destination, limits: .default)
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled conversion completed")
        } catch {
            XCTAssertEqual(error as? RARError, .cancelled)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["in.cbr"])
    }

    /// Cancelled after the first output chunk: compressed (decoder) and
    /// stored (extractor) entries stop at the next one.
    func testCancelledExtractionStopsAtTheNextChunk() async throws {
        for name in ["rar5-m3-big", "rar4-m3-big", "rar5-m0"] {
            let bytes = try fixtures.fixture(name)
            let task = Task.detached { () -> Int in
                let source = DataSource(bytes)
                let archive = try RARArchive(source: source, limits: .default)
                var entry = try XCTUnwrap(archive.entries.max { $0.unpackedSize < $1.unpackedSize })
                // A RAR5 entry that fits its window comes out as one chunk.
                // A smaller dictionary makes the window wrap, so there is a
                // next chunk; the output is wrong then, but never checked.
                if entry.unpackVersion != 29 { entry.dictionarySize = 256 << 10 }
                var chunks = 0
                let sink: ([UInt8]) throws -> Void = { _ in
                    chunks += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                do {
                    if entry.isStored {
                        try StoredExtractor.extract(entry, from: source, into: sink)
                    } else {
                        try RARDecoder.Session(archive: archive, limits: .default).decode(entry, from: source, into: sink)
                    }
                } catch RARError.cancelled {
                    return chunks
                }
                return -chunks
            }
            let chunks = try await task.value
            XCTAssertEqual(chunks, 1, "\(name): negative means it ran to the end")
        }
    }

    /// Follow-up review of fb64b49: decoding that writes nothing never
    /// reached the per-chunk check. 400,000 repeat-last symbols without an
    /// earlier match produce no bytes; cancelled at the first read of the
    /// compressed data, the conversion used to succeed anyway.
    func testCancellationStopsDecodingThatProducesNoOutput() async throws {
        var stream = RAR5Stream(extended: false)
        for _ in 0..<400_000 { stream.repeatLast() }
        var file = TestFile(name: "p.jpg", contents: stream.bytes(), rar5Compression: 3 << 7)
        file.unpackedSizeOverride = 0
        file.crcOverride = 0
        let bytes = RAR5Builder.build([file])
        let dataOffset = try XCTUnwrap(RARArchive(source: DataSource(bytes), limits: .default).entries.first).dataOffset

        let task = Task.detached { () -> (RARError?, Int) in
            let source = CancellingSource(DataSource(bytes), cancelAt: dataOffset)
            do {
                _ = try convertToCBZ(source: source, output: MemoryOutput(), limits: .default)
                return (nil, source.readsAfterCancel)
            } catch {
                return (error as? RARError, source.readsAfterCancel)
            }
        }
        let (error, readsAfterCancel) = await task.value
        XCTAssertEqual(error, .cancelled)
        XCTAssertEqual(readsAfterCancel, 0)
    }

    func testCancelledParseStops() async throws {
        let bytes = try fixtures.fixture("rar4-m3")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try RARArchive(source: DataSource(bytes), limits: .default).entries.count
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled parse completed")
        } catch {
            XCTAssertEqual(error as? RARError, .cancelled)
        }
    }
}

/// Cancels the current task when the first read at `cancelAt` happens, and
/// counts the reads that follow.
final class CancellingSource: ByteSource {
    private let base: ByteSource
    private let cancelAt: UInt64
    private var cancelled = false
    private(set) var readsAfterCancel = 0

    init(_ base: ByteSource, cancelAt: UInt64) {
        self.base = base
        self.cancelAt = cancelAt
    }

    var size: UInt64 { base.size }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        if cancelled {
            readsAfterCancel += 1
        } else if offset == cancelAt {
            cancelled = true
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return try base.read(at: offset, count: count)
    }
}
