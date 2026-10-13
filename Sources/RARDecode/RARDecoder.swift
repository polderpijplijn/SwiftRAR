// This target (RARDecode) is licensed under the unRAR license, not MIT.
// See LICENSE-UNRAR in this directory. Required notice from that license:
//
//   UnRAR source code may be used in any software to handle
//   RAR archives without limitations free of charge, but cannot be
//   used to develop RAR (WinRAR) compatible archiver and to
//   re-create RAR compression algorithm, which is proprietary.
//   Distribution of modified UnRAR source code in separate form
//   or as a part of other software is permitted, provided that
//   full text of this paragraph, starting from "UnRAR source code"
//   words, is included in license, or in documentation if license
//   is not available, and in source code comments of resulting package.
//
// Decompression only. Nothing in this target may be used to create or
// compress RAR archives.

import RARCore

/// Decompression of compressed RAR entries: a Swift port of RARLAB's UnRAR.
///
/// Supported so far: RAR4 UnpVer 29 (LZ + Huffman and PPMd variant H) with
/// the standard RarVM filters, solid or not. A later phase adds unpack50
/// (RAR5).
public enum RARDecoder {
    /// Whether this decoder can unpack the entry. Unknown filter programs
    /// only show up inside the data; decoding throws
    /// `.unsupportedCompression` then.
    public static func canDecode(_ entry: RAREntry) -> Bool {
        !entry.isStored && !entry.isEncrypted && !entry.isSplit && entry.unpackVersion == 29
    }

    /// Unpacks a single compressed entry with a fresh session. A solid entry
    /// needs the entries before it: use a `Session` for those.
    public static func decode(
        _ entry: RAREntry,
        from source: ByteSource,
        limits: Limits,
        into sink: ([UInt8]) throws -> Void
    ) throws {
        try Session(limits: limits).decode(entry, from: source, into: sink)
    }

    /// Decoder state for one archive. Decode its compressed entries in
    /// archive order: a solid entry continues from the window, tables and
    /// filters of the entry before it.
    public final class Session {
        private let limits: Limits
        private var unpack: Unpack29?
        /// Set when an entry failed; the solid stream after it is unusable.
        private var failed = false

        public init(limits: Limits) {
            self.limits = limits
        }

        /// How often each standard filter ran in this session.
        public var appliedFilters: [StandardFilter: Int] { unpack?.appliedFilters ?? [:] }

        /// Which PPMd paths this session went through.
        public var ppmdCoverage: PPMdCoverage { unpack?.ppmCoverage ?? PPMdCoverage() }

        /// Unpacks a compressed entry, streaming the output to `sink`, and
        /// verifies its CRC32.
        ///
        /// On an error the data written so far has already reached `sink`;
        /// the caller must discard its output (SwiftRAR deletes the partial
        /// file).
        public func decode(_ entry: RAREntry, from source: ByteSource, into sink: ([UInt8]) throws -> Void) throws {
            guard !entry.isEncrypted else { throw RARError.encrypted }
            guard !entry.isSplit else { throw RARError.multiVolume }
            guard Self.canDecode(entry) else { throw RARError.unsupportedCompression(method: entry.method) }
            guard let expectedCRC = entry.crc32 else { throw RARError.missingChecksum(entry: entry.rawName) }
            guard entry.dictionarySize <= limits.maxDictionarySize else { throw RARError.limitExceeded(.dictionarySize) }
            guard entry.unpackedSize <= limits.maxEntrySize else { throw RARError.limitExceeded(.entrySize) }
            if entry.isSolid && failed {
                throw RARError.corruptData("solid stream broken by an earlier entry")
            }

            failed = true
            let input = try StreamBitReader(source: source, offset: entry.dataOffset, count: entry.packedSize)
            var state = try unpack ?? Unpack29()
            unpack = nil
            var crc = CRC32()
            try state.decode(method: entry.method, input: input, outputSize: entry.unpackedSize,
                             dictionarySize: entry.dictionarySize, ppmMemoryLimit: limits.maxPPMdMemory,
                             solid: entry.isSolid) { chunk in
                crc.update(chunk)
                try sink(chunk)
            }
            unpack = state
            if crc.value != expectedCRC { throw RARError.badDataCRC(entry: entry.rawName) }
            failed = false
        }

        private static func canDecode(_ entry: RAREntry) -> Bool { RARDecoder.canDecode(entry) }
    }
}
