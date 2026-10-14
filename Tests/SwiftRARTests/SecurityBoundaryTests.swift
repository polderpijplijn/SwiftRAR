// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import SwiftRAR
@testable import RARCore

/// Regression coverage for the security review in issue #5.
final class SecurityBoundaryTests: XCTestCase {
    func testFileOutputRejectsDanglingSymlinkWithoutCreatingTarget() throws {
        let directory = try makeTemporaryDirectory(self)
        let target = directory.appendingPathComponent("missing.txt")
        let output = directory.appendingPathComponent("output.cbz")
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: target)

        XCTAssertThrowsError(try FileOutput(url: output)) {
            guard case .io = $0 as? CBZWriterError else { return XCTFail("unexpected error: \($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: output.path), target.path)
    }

    func testFileOutputPreservesExistingFileAndSymlinkTarget() throws {
        let directory = try makeTemporaryDirectory(self)
        let target = directory.appendingPathComponent("existing.txt")
        let link = directory.appendingPathComponent("output.cbz")
        let original = Data("KEEP-ME-UNCHANGED".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        for url in [target, link] {
            XCTAssertThrowsError(try FileOutput(url: url))
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testFileOutputKeepsItsDescriptorWhenPathIsReplaced() throws {
        let directory = try makeTemporaryDirectory(self)
        let path = directory.appendingPathComponent("output.cbz")
        let moved = directory.appendingPathComponent("original-output.cbz")
        let victim = directory.appendingPathComponent("victim.txt")
        let original = Data("KEEP-ME-UNCHANGED".utf8)
        try original.write(to: victim)
        let output = try FileOutput(url: path)
        try FileManager.default.moveItem(at: path, to: moved)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: victim)

        try output.write([1, 2, 3])
        try output.overwrite(at: 1, with: [4])
        try output.close()
        XCTAssertEqual(try Data(contentsOf: victim), original)
        XCTAssertEqual(Array(try Data(contentsOf: moved)), [1, 4, 3])
    }

    func testRAR5RejectsHeaderBeforeReadingBeyondRemainingBudget() throws {
        let main = RAR5Builder.header(type: 1, flags: 0, fields: [0])
        let large = RAR5Builder.header(type: 99, flags: 0, fields: [UInt8](repeating: 0, count: 1 << 20))
        // Both the first header and a later header must be checked before
        // their body is read; a per-header check alone misses the latter.
        let cases: [([UInt8], UInt64)] = [
            ([], 64),
            (main, UInt64(main.count + 64)),
            // The large header fits the absolute limit but exceeds the
            // remaining budget by one byte after the main header.
            (main, UInt64(main.count + large.count - 1)),
        ]
        for (prefix, budget) in cases {
            let source = HeaderReadProbe(ArchiveFormat.rar5Magic + prefix + large)
            var limits = Limits.default
            limits.maxHeaderBytes = budget
            XCTAssertThrowsError(try RARArchive(source: source, limits: limits)) {
                XCTAssertEqual($0 as? RARError, .limitExceeded(.headerBytes))
            }
            XCTAssertLessThanOrEqual(source.largestRead, 14, "only the size prefix may be read")
        }
    }

    func testRAR5AcceptsExactHeaderBudget() throws {
        let payload: [UInt8] = [1, 2, 3]
        let bytes = RAR5Builder.build([TestFile(name: "a", contents: payload)])
        var limits = Limits.default
        limits.maxHeaderBytes = UInt64(bytes.count - ArchiveFormat.rar5Magic.count - payload.count)
        let reader = try RARReader(source: DataSource(bytes), limits: limits)
        XCTAssertEqual(Array(try reader.data(for: XCTUnwrap(reader.entries.first))), payload)

        limits.maxHeaderBytes -= 1
        XCTAssertThrowsError(try RARReader(source: DataSource(bytes), limits: limits)) {
            XCTAssertEqual($0 as? RARError, .limitExceeded(.headerBytes))
        }
    }

    func testReaderRejectsForeignEntryWithIdenticalMetadata() throws {
        let bytes = RAR5Builder.build([TestFile(name: "a", contents: [65])])
        let first = try RARReader(source: DataSource(bytes), limits: .default)
        let foreign = try XCTUnwrap(first.entries.first)
        // Even opening the exact same archive twice creates distinct owners.
        for otherBytes in [bytes, RAR5Builder.build([TestFile(name: "a", contents: [66])])] {
            let second = try RARReader(source: DataSource(otherBytes), limits: .default)
            var received: [UInt8] = []
            XCTAssertThrowsError(try second.extract(foreign) { received += $0 }) {
                XCTAssertEqual($0 as? RARError, .invalidEntryName(foreign.name))
            }
            XCTAssertTrue(received.isEmpty)
            XCTAssertThrowsError(try second.data(for: foreign)) {
                XCTAssertEqual($0 as? RARError, .invalidEntryName(foreign.name))
            }
            let own = try XCTUnwrap(second.entries.first)
            XCTAssertNoThrow(try second.data(for: own))
        }
        XCTAssertEqual(Array(try first.data(for: foreign)), [65])
    }
}

private final class HeaderReadProbe: ByteSource {
    private let base: DataSource
    private(set) var largestRead = 0
    var size: UInt64 { base.size }

    init(_ bytes: [UInt8]) { base = DataSource(bytes) }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        largestRead = max(largestRead, count)
        return try base.read(at: offset, count: count)
    }
}
