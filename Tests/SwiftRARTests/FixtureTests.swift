// SPDX-License-Identifier: MIT

import XCTest
import SwiftRAR

/// Archives made by the real `rar` (see Tools/fixtures/make-fixtures.sh).
///
/// Naming: `<rar4|rar5>-<variant>.rar`. Fixtures in `supported` must convert
/// and match the unrar oracle byte for byte; every other fixture is expected
/// to fail with `.unsupportedCompression` until its phase lands.
final class FixtureTests: XCTestCase {
    /// File stems, not variants: `rar4-m3` is supported before `rar5-m3`.
    static let supported: Set<String> = [
        "rar4-m0", "rar5-m0", "rar4-m3", "rar4-m3-md64", "rar4-m3-big",
        "rar4-m3-flt", "rar4-s", "rar4-s-flt", "rar4-s-link",
        "rar4-flt-e8", "rar4-flt-audio", "rar4-flt-delta", "rar4-flt-rgb",
        "rar4-mct", "rar4-mct-s", "rar4-mct-mix", "rar4-mct-mem", "rar4-mct-flt",
        "rar4-mct-rep", "rar5-m3", "rar5-s", "rar5-mct",
        "rar5-m3-md128", "rar5-m3-big", "rar5-flt-e8", "rar5-flt-delta", "rar5-s-flt", "rar5-s-link",
    ]

    /// Fixtures that need looser limits than `.default`. In a solid RAR5
    /// stream a near-copy of an earlier file packs to almost nothing:
    /// `ComicInfo.xml` in `rar5-s` (1185:1) and `a.txt` in `rar5-s-link`,
    /// which RAR 7 puts after `c.txt` that contains it (1268:1).
    static let limitOverrides: [String: Limits] = {
        var looser = Limits.default
        looser.maxCompressionRatio = 2_000
        return ["rar5-s": looser, "rar5-s-link": looser]
    }()

    func fixtures() throws -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: Tools.fixturesDirectory, includingPropertiesForKeys: nil)) ?? []
        let rars = all.filter { $0.pathExtension == "rar" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if rars.isEmpty { throw Tools.unavailable("no fixtures; run Tools/fixtures/make-fixtures.sh ") }
        return rars
    }

    func isSupported(_ url: URL) -> Bool {
        Self.supported.contains(url.deletingPathExtension().lastPathComponent)
    }

    func testSupportedFixturesMatchOracle() throws {
        let unrar = try Tools.requireUnrar()
        let unzip = try Tools.requireUnzip()
        let supported = try fixtures().filter(isSupported)
        XCTAssertEqual(supported.count, Self.supported.count, "missing supported fixtures")
        let directory = try makeTemporaryDirectory(self)
        let helper = ConversionTests()
        for url in supported {
            let limits = Self.limitOverrides[url.deletingPathExtension().lastPathComponent] ?? .default
            try helper.assertMatchesOracle(input: url, unrar: unrar, unzip: unzip, in: directory, limits: limits)
        }
    }

    func testOtherFixturesAreUnsupported() throws {
        let compressed = try fixtures().filter { !isSupported($0) }
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
