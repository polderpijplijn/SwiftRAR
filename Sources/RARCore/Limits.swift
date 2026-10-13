// SPDX-License-Identifier: MIT

/// Bounds that protect against malicious or absurd archives.
///
/// A required parameter of every public entry point; `Limits.default` is safe
/// for comic books on an iPhone. Looser bounds are a deliberate caller choice.
public struct Limits: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case entries
        case entrySize
        case totalSize
        case compressionRatio
        case nameLength
        case dictionarySize
        case ppmdMemory
        case headerBytes
    }

    /// Maximum number of file headers (directories included) in the archive.
    public var maxEntries: Int
    /// Maximum unpacked size of a single entry, in bytes.
    public var maxEntrySize: UInt64
    /// Maximum unpacked size of all entries together, in bytes.
    public var maxTotalSize: UInt64
    /// Maximum ratio unpacked / packed per entry.
    public var maxCompressionRatio: UInt64
    /// Maximum file name length in UTF-8 bytes.
    public var maxNameLength: Int
    /// Maximum dictionary size a compressed entry may request, in bytes.
    public var maxDictionarySize: UInt64
    /// Maximum PPMd model memory a RAR4 text block may request, in bytes.
    public var maxPPMdMemory: UInt64
    /// Maximum size of all headers together, in bytes, every block type
    /// included: what the parser reads and keeps before any data is touched.
    public var maxHeaderBytes: UInt64

    public init(
        maxEntries: Int,
        maxEntrySize: UInt64,
        maxTotalSize: UInt64,
        maxCompressionRatio: UInt64,
        maxNameLength: Int,
        maxDictionarySize: UInt64,
        maxPPMdMemory: UInt64 = 256 << 20,
        maxHeaderBytes: UInt64 = 16 << 20
    ) {
        self.maxEntries = maxEntries
        self.maxEntrySize = maxEntrySize
        self.maxTotalSize = maxTotalSize
        self.maxCompressionRatio = maxCompressionRatio
        self.maxNameLength = maxNameLength
        self.maxDictionarySize = maxDictionarySize
        self.maxPPMdMemory = maxPPMdMemory
        self.maxHeaderBytes = maxHeaderBytes
    }

    /// Safe default: generous for any comic book, tight for a zip bomb.
    public static let `default` = Limits(
        maxEntries: 10_000,
        maxEntrySize: 256 << 20,           // 256 MiB per page
        maxTotalSize: 4_000_000_000,       // just under the non-ZIP64 limit
        maxCompressionRatio: 1_000,
        maxNameLength: 1_024,
        maxDictionarySize: 256 << 20,      // 256 MiB; RAR5 can ask for up to 1 TB
        maxPPMdMemory: 256 << 20,          // 256 MiB, the most a PPMd header can ask for
        maxHeaderBytes: 16 << 20           // 16 MiB of headers: far beyond 10,000 pages
    )
}
