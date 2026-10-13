// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// Locates external tools for tests. Tests that need a missing tool are skipped.
enum Tools {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // SwiftRARTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent()

    static let fixturesDirectory = repositoryRoot.appendingPathComponent("Tests/Fixtures")

    /// The official unrar: $SWIFTRAR_UNRAR, the local oracle build, or Homebrew.
    static var unrar: URL? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["SWIFTRAR_UNRAR"] { candidates.append(env) }
        candidates += [
            repositoryRoot.appendingPathComponent("Tools/oracle/.build/unrar/unrar").path,
            "/opt/homebrew/bin/unrar",
            "/usr/local/bin/unrar",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Used for `unzip -t` (integrity). Not for extraction: macOS unzip ignores
    /// the UTF-8 flag and mangles non-ASCII names.
    static var unzip: URL? {
        ["/usr/bin/unzip"].first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// libarchive's tar, which honours the ZIP UTF-8 flag. Used to extract CBZs.
    static var bsdtar: URL? {
        ["/usr/bin/bsdtar", "/usr/bin/tar"].first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static func requireBsdtar() throws -> URL {
        guard let bsdtar else { throw XCTSkip("bsdtar not found") }
        return bsdtar
    }

    /// Extracts a ZIP into `directory` (created if needed).
    static func extractZIP(_ zip: URL, to directory: URL) throws -> (status: Int32, output: String) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try run(try requireBsdtar(), ["-xf", zip.path, "-C", directory.path])
    }

    static func requireUnrar() throws -> URL {
        guard let unrar else { throw XCTSkip("unrar oracle not found; run Tools/oracle/build-unrar.sh") }
        return unrar
    }

    static func requireUnzip() throws -> URL {
        guard let unzip else { throw XCTSkip("unzip not found") }
        return unzip
    }

    @discardableResult
    static func run(_ tool: URL, _ arguments: [String], in directory: URL? = nil) throws -> (status: Int32, output: String) {
        #if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        #else
        throw XCTSkip("Process is unavailable on this platform")
        #endif
    }
}

/// A fresh temporary directory, removed when the test ends.
func makeTemporaryDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftRARTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

/// All regular files below `root`, as relative path -> contents.
func readTree(_ root: URL) throws -> [String: [UInt8]] {
    var result: [String: [UInt8]] = [:]
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return result
    }
    for case let url as URL in enumerator {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let relative = String(path.dropFirst(rootPath.count + 1))
        // Compare names in NFC: HFS+/APFS may hand back decomposed forms.
        result[relative.precomposedStringWithCanonicalMapping] = [UInt8](try Data(contentsOf: url))
    }
    return result
}
