// SPDX-License-Identifier: MIT

import XCTest
import CBZWriter
import RARCore

/// Pretends to be a huge file without storing anything, to test the 4 GiB checks.
final class CountingOutput: ZIPOutput {
    var position: UInt64
    init(startingAt position: UInt64) { self.position = position }
    func write(_ bytes: [UInt8]) throws { position += UInt64(bytes.count) }
    func overwrite(at offset: UInt64, with bytes: [UInt8]) throws {}
}

final class CBZWriterTests: XCTestCase {
    func testRoundTripWithUnzip() throws {
        let unzip = try Tools.requireUnzip()
        let directory = try makeTemporaryDirectory(self)
        let url = directory.appendingPathComponent("out.cbz")
        let output = try FileOutput(url: url)
        let writer = CBZWriter(output: output)
        let files: [(String, [UInt8])] = [
            ("pages/001.jpg", randomBytes(100_000, seed: 11)),
            ("pages/002.jpg", randomBytes(5, seed: 12)),
            ("empty.txt", []),
            ("één – ünïcode.txt", Array("hoi".utf8)),
        ]
        for (name, contents) in files {
            try writer.beginEntry(name: name, modified: Date(timeIntervalSince1970: 1_715_949_296))
            // Stream in uneven chunks.
            var offset = 0
            while offset < contents.count {
                let end = min(contents.count, offset + 7_777)
                try writer.write(Array(contents[offset..<end]))
                offset = end
            }
            XCTAssertEqual(try writer.endEntry(), CRC32.checksum(contents))
        }
        try writer.finish()
        try output.close()

        let test = try Tools.run(unzip, ["-t", url.path])
        XCTAssertEqual(test.status, 0, test.output)
        XCTAssertTrue(test.output.contains("No errors detected"), test.output)

        let extracted = directory.appendingPathComponent("x")
        let unpack = try Tools.extractZIP(url, to: extracted)
        XCTAssertEqual(unpack.status, 0, unpack.output)
        let tree = try readTree(extracted)
        XCTAssertEqual(tree.count, files.count)
        for (name, contents) in files {
            XCTAssertEqual(tree[name.precomposedStringWithCanonicalMapping], contents, name)
        }
    }

    func testStructure() throws {
        let output = MemoryOutput()
        let writer = CBZWriter(output: output)
        try writer.addEntry(name: "a.txt", modified: nil, contents: Array("abc".utf8))
        try writer.finish()
        let zip = output.bytes
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(zip[6], 0x00); XCTAssertEqual(zip[7], 0x08)      // UTF-8 flag
        XCTAssertEqual(zip[8], 0); XCTAssertEqual(zip[9], 0)            // stored
        let end = Array(zip.suffix(22))
        XCTAssertEqual(Array(end.prefix(4)), [0x50, 0x4B, 0x05, 0x06])
        XCTAssertEqual(end[10], 1)                                      // one entry
    }

    func testInvalidNames() {
        let writer = CBZWriter(output: MemoryOutput())
        for name in ["", "/abs", "a/../b", "a//b", "a\\b", "./a", "x\u{0}"] {
            XCTAssertThrowsError(try writer.beginEntry(name: name, modified: nil), name)
        }
    }

    func testDuplicateName() throws {
        let writer = CBZWriter(output: MemoryOutput())
        try writer.addEntry(name: "a", modified: nil, contents: [])
        XCTAssertThrowsError(try writer.addEntry(name: "a", modified: nil, contents: [])) {
            XCTAssertEqual($0 as? CBZWriterError, .duplicateName("a"))
        }
    }

    func testCallOrder() throws {
        let writer = CBZWriter(output: MemoryOutput())
        XCTAssertThrowsError(try writer.write([1]))
        XCTAssertThrowsError(try writer.endEntry())
        try writer.beginEntry(name: "a", modified: nil)
        XCTAssertThrowsError(try writer.beginEntry(name: "b", modified: nil))
        XCTAssertThrowsError(try writer.finish())
        try writer.endEntry()
        try writer.finish()
        XCTAssertThrowsError(try writer.beginEntry(name: "c", modified: nil))
    }

    func testRefusesZIP64Offsets() throws {
        let writer = CBZWriter(output: CountingOutput(startingAt: 0xFFFF_FF00))
        try writer.beginEntry(name: "a", modified: nil)
        XCTAssertThrowsError(try writer.write([UInt8](repeating: 0, count: 1_000))) {
            XCTAssertEqual($0 as? CBZWriterError, .zip64Required)
        }

        let late = CBZWriter(output: CountingOutput(startingAt: 0xFFFF_FFFF))
        XCTAssertThrowsError(try late.beginEntry(name: "a", modified: nil)) {
            XCTAssertEqual($0 as? CBZWriterError, .zip64Required)
        }
    }

    func testRefusesTooManyEntries() throws {
        let writer = CBZWriter(output: CountingOutput(startingAt: 0))
        for index in 0..<CBZWriter.maxEntries {
            try writer.addEntry(name: "\(index)", modified: nil, contents: [])
        }
        XCTAssertThrowsError(try writer.addEntry(name: "one-too-many", modified: nil, contents: [])) {
            XCTAssertEqual($0 as? CBZWriterError, .tooManyEntries)
        }
    }
}
