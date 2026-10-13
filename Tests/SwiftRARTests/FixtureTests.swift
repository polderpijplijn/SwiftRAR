// SPDX-License-Identifier: MIT

import XCTest
import SwiftRAR

/// Archives made by the real `rar` (see Tools/fixtures/make-fixtures.sh).
///
/// Naming: `<rar4|rar5>-<variant>.rar`. Variants `m0` (store) must convert
/// and match the unrar oracle byte for byte; every other variant is expected
/// to fail with `.unsupportedCompression` until its phase lands.
final class FixtureTests: XCTestCase {
    static let storedVariants: Set<String> = ["m0"]

    func fixtures() throws -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: Tools.fixturesDirectory, includingPropertiesForKeys: nil)) ?? []
        let rars = all.filter { $0.pathExtension == "rar" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if rars.isEmpty { throw XCTSkip("no fixtures; run Tools/fixtures/make-fixtures.sh (needs rar)") }
        return rars
    }

    func variant(of url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return String(stem.split(separator: "-", maxSplits: 1).last ?? "")
    }

    func testStoredFixturesMatchOracle() throws {
        let unrar = try Tools.requireUnrar()
        let unzip = try Tools.requireUnzip()
        let stored = try fixtures().filter { Self.storedVariants.contains(variant(of: $0)) }
        XCTAssertFalse(stored.isEmpty, "no store fixtures found")
        let directory = try makeTemporaryDirectory(self)
        let helper = ConversionTests()
        for url in stored {
            try helper.assertMatchesOracle(input: url, unrar: unrar, unzip: unzip, in: directory)
        }
    }

    func testCompressedFixturesAreUnsupported() throws {
        let compressed = try fixtures().filter { !Self.storedVariants.contains(variant(of: $0)) }
        let directory = try makeTemporaryDirectory(self)
        for url in compressed {
            let output = directory.appendingPathComponent(url.lastPathComponent + ".cbz")
            XCTAssertThrowsError(try convertToCBZ(from: url, to: output, limits: .default), url.lastPathComponent) {
                guard case .unsupportedCompression = $0 as? RARError else {
                    return XCTFail("\(url.lastPathComponent): expected .unsupportedCompression, got \($0)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testFixturesParse() throws {
        for url in try fixtures() {
            let archive = try RARArchive(source: FileSource(url: url), limits: .default)
            XCTAssertFalse(archive.entries.isEmpty, url.lastPathComponent)
        }
    }
}
