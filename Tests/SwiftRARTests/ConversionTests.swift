// SPDX-License-Identifier: MIT

import XCTest
import SwiftRAR

/// File-level conversion: atomic output, cleanup on failure, ZIP passthrough,
/// and byte-exact comparison against the official unrar oracle.
final class ConversionTests: XCTestCase {
    func write(_ bytes: [UInt8], to url: URL) throws {
        try Data(bytes).write(to: url)
    }

    func leftovers(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".partial") }
    }

    func testConvertsRAR5ToValidCBZ() throws {
        let unzip = try Tools.requireUnzip()
        let directory = try makeTemporaryDirectory(self)
        let input = directory.appendingPathComponent("book.cbr")
        let output = directory.appendingPathComponent("book.cbz")
        try write(RAR5Builder.build(sampleFiles()), to: input)

        let result = try convertToCBZ(from: input, to: output, limits: .default)
        XCTAssertEqual(result.entryCount, 4)
        let test = try Tools.run(unzip, ["-t", output.path])
        XCTAssertEqual(test.status, 0, test.output)
        XCTAssertEqual(try leftovers(in: directory), [])
    }

    func testReportsProgressPerEntryUpToOne() throws {
        let directory = try makeTemporaryDirectory(self)
        let input = directory.appendingPathComponent("book.cbr")
        let output = directory.appendingPathComponent("book.cbz")
        try write(RAR4Builder.build(sampleFiles()), to: input)

        var reported: [Double] = []
        let result = try convertToCBZ(from: input, to: output, limits: .default) { reported.append($0) }
        XCTAssertEqual(reported.count, result.entryCount)
        XCTAssertEqual(reported, reported.sorted())
        XCTAssertGreaterThan(reported.first ?? 0, 0)
        XCTAssertEqual(reported.last, 1)
    }

    func testReportsProgressForZIPPassthrough() throws {
        let directory = try makeTemporaryDirectory(self)
        let zipOutput = MemoryOutput()
        let writer = CBZWriter(output: zipOutput)
        try writer.addEntry(name: "p.jpg", modified: nil, contents: [1, 2, 3])
        try writer.finish()
        let input = directory.appendingPathComponent("in.cbz")
        try write(zipOutput.bytes, to: input)

        var reported: [Double] = []
        try convertToCBZ(from: input, to: directory.appendingPathComponent("out.cbz"),
                         limits: .default) { reported.append($0) }
        XCTAssertEqual(reported.last, 1)
    }

    func testZIPIsCopiedUnchanged() throws {
        let directory = try makeTemporaryDirectory(self)
        let zipOutput = MemoryOutput()
        let writer = CBZWriter(output: zipOutput)
        try writer.addEntry(name: "p.jpg", modified: nil, contents: [1, 2, 3])
        try writer.finish()
        let input = directory.appendingPathComponent("in.cbz")
        let output = directory.appendingPathComponent("out.cbz")
        try write(zipOutput.bytes, to: input)

        let result = try convertToCBZ(from: input, to: output, limits: .default)
        XCTAssertEqual(result.sourceFormat, .zip)
        XCTAssertEqual([UInt8](try Data(contentsOf: output)), zipOutput.bytes)
    }

    func testCRCMismatchLeavesNoFile() throws {
        let directory = try makeTemporaryDirectory(self)
        let input = directory.appendingPathComponent("bad.cbr")
        let output = directory.appendingPathComponent("bad.cbz")
        var files = sampleFiles()
        files[1].crcOverride = 0xDEAD_BEEF // second page: the first is already written
        try write(RAR4Builder.build(files), to: input)

        XCTAssertThrowsError(try convertToCBZ(from: input, to: output, limits: .default)) {
            XCTAssertEqual($0 as? RARError, .badDataCRC(entry: "comic/page02.png"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try leftovers(in: directory), [])
    }

    func testFailureKeepsExistingDestination() throws {
        let directory = try makeTemporaryDirectory(self)
        let input = directory.appendingPathComponent("junk.cbr")
        let output = directory.appendingPathComponent("existing.cbz")
        try write(Array("not an archive".utf8), to: input)
        try write([42], to: output)

        XCTAssertThrowsError(try convertToCBZ(from: input, to: output, limits: .default)) {
            XCTAssertEqual($0 as? RARError, .unknownFormat)
        }
        XCTAssertEqual([UInt8](try Data(contentsOf: output)), [42])
        XCTAssertEqual(try leftovers(in: directory), [])
    }

    func testSuccessReplacesExistingDestination() throws {
        let directory = try makeTemporaryDirectory(self)
        let input = directory.appendingPathComponent("book.cbr")
        let output = directory.appendingPathComponent("book.cbz")
        try write(RAR4Builder.build(sampleFiles()), to: input)
        try write([42], to: output)
        try convertToCBZ(from: input, to: output, limits: .default)
        XCTAssertEqual(Array([UInt8](try Data(contentsOf: output)).prefix(2)), [0x50, 0x4B])
    }

    func testMissingInput() throws {
        let directory = try makeTemporaryDirectory(self)
        XCTAssertThrowsError(try convertToCBZ(from: directory.appendingPathComponent("nope.cbr"),
                                              to: directory.appendingPathComponent("x.cbz"), limits: .default)) {
            guard case .io = $0 as? RARError else { return XCTFail("expected .io, got \($0)") }
        }
    }

    // MARK: - Oracle

    /// Hand-built RAR4 and RAR5 store archives: SwiftRAR's CBZ, unpacked with
    /// unzip, must equal `unrar x` output byte for byte.
    func testHandBuiltArchivesMatchOracle() throws {
        for (label, bytes) in [("rar4", RAR4Builder.build(sampleFiles())), ("rar5", RAR5Builder.build(sampleFiles()))] {
            try assertMatchesOracle(archive: bytes, label: label)
        }
    }

    func assertMatchesOracle(archive bytes: [UInt8], label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let unrar = try Tools.requireUnrar()
        let unzip = try Tools.requireUnzip()
        let directory = try makeTemporaryDirectory(self)
        let input = directory.appendingPathComponent("\(label).rar")
        try write(bytes, to: input)
        try assertMatchesOracle(input: input, unrar: unrar, unzip: unzip, in: directory, file: file, line: line)
    }

    func assertMatchesOracle(input: URL, unrar: URL, unzip: URL, in directory: URL, limits: Limits = .default,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let oracleDirectory = directory.appendingPathComponent("oracle-\(input.lastPathComponent)")
        try FileManager.default.createDirectory(at: oracleDirectory, withIntermediateDirectories: true)
        let oracle = try Tools.run(unrar, ["x", "-y", "-idq", input.path, oracleDirectory.path + "/"])
        XCTAssertEqual(oracle.status, 0, "unrar: \(oracle.output)", file: file, line: line)

        let cbz = directory.appendingPathComponent("\(input.lastPathComponent).cbz")
        try convertToCBZ(from: input, to: cbz, limits: limits)
        let ours = directory.appendingPathComponent("ours-\(input.lastPathComponent)")
        let integrity = try Tools.run(unzip, ["-t", cbz.path])
        XCTAssertEqual(integrity.status, 0, integrity.output, file: file, line: line)
        let unpack = try Tools.extractZIP(cbz, to: ours)
        XCTAssertEqual(unpack.status, 0, unpack.output, file: file, line: line)

        let expected = try readTree(oracleDirectory)
        let actual = try readTree(ours)
        XCTAssertFalse(expected.isEmpty, "oracle extracted nothing", file: file, line: line)
        XCTAssertEqual(Set(actual.keys), Set(expected.keys), file: file, line: line)
        for (name, contents) in expected {
            XCTAssertTrue(actual[name] == contents, "\(name) differs from oracle", file: file, line: line)
        }
    }
}
