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
/// Supported: RAR4 UnpVer 29 (LZ + Huffman and PPMd variant H) with the
/// standard RarVM filters, and RAR5 (unpack50, both the RAR 5.0 and the
/// RAR 7.0 algorithm) with its four filters, solid or not.
public enum RARDecoder {
    /// Whether this decoder can unpack the entry. Unknown filter programs
    /// only show up inside the data; decoding throws
    /// `.unsupportedCompression` then.
    public static func canDecode(_ entry: RAREntry) -> Bool {
        !entry.isStored && !entry.isEncrypted && !entry.isSplit
            && [29, RAREntry.unpackVersionRAR5, RAREntry.unpackVersionRAR7].contains(entry.unpackVersion)
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
        /// Bounds the LZ window by the data it can ever hold (see `init(archive:limits:)`).
        private let windowBound: WindowBound
        private var unpack: Unpack29?
        private var unpack50: Unpack50?
        /// Set when an entry failed; the solid stream after it is unusable.
        private var failed = false

        enum WindowBound {
            /// The window follows the dictionary size in the header.
            case dictionary
            /// Non-solid: each entry is a stream of its own.
            case entry
            /// Solid: all compressed entries form one stream of this size.
            case stream(UInt64)
        }

        /// A session without knowledge of the archive: every window is as
        /// large as its entry's dictionary.
        public init(limits: Limits) {
            self.limits = limits
            self.windowBound = .dictionary
        }

        /// A session for the entries of `archive`. A stream never refers
        /// further back than the bytes it produced, so the window is at most
        /// the entry's size (non-solid) or that of all compressed entries
        /// together (solid), plus `windowSlack`. A tiny entry that asks for a
        /// 256 MiB dictionary then costs 256 KB. Output of valid archives is
        /// the same.
        public init(archive: RARArchive, limits: Limits) {
            self.limits = limits
            if archive.isSolid {
                var total: UInt64 = 0
                for entry in archive.entries where !entry.isStored && !entry.isDirectory && !entry.isLink {
                    total = Self.saturatingAdd(total, Self.saturatingAdd(entry.unpackedSize, Self.windowSlack))
                }
                windowBound = .stream(total)
            } else {
                windowBound = .entry
            }
        }

        /// Room beyond the data in a bounded window. The window must stay
        /// larger than everything the stream writes: a filter block is held
        /// back until it is complete (in RAR5 up to the whole entry), and a
        /// window that fills up wraps onto the write position, where full
        /// reads as empty. A stream may also write one match past its end
        /// (0x1004 bytes at most).
        static let windowSlack: UInt64 = 0x10000

        private static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let (sum, overflow) = a.addingReportingOverflow(b)
            return overflow ? .max : sum
        }

        /// Bytes allocated for the LZ windows (for tests).
        var windowBytes: Int { (unpack?.windowCount ?? 0) + (unpack50?.windowCount ?? 0) }

        /// How often each standard filter ran in this session.
        public var appliedFilters: [StandardFilter: Int] { unpack?.appliedFilters ?? [:] }

        /// Which PPMd paths this session went through.
        public var ppmdCoverage: PPMdCoverage { unpack?.ppmCoverage ?? PPMdCoverage() }

        /// Which unpack50 (RAR5) paths this session went through.
        public var rar5Coverage: RAR5Coverage { unpack50?.coverage ?? RAR5Coverage() }

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

            let window: UInt64
            switch windowBound {
            case .dictionary: window = entry.dictionarySize
            case .entry: window = min(entry.dictionarySize, Self.saturatingAdd(entry.unpackedSize, Self.windowSlack))
            case .stream(let size): window = min(entry.dictionarySize, size)
            }

            if Task.isCancelled { throw RARError.cancelled }
            failed = true
            // Decoding can run long without output (repeats of nothing,
            // tables, filters), so the input checks too, at every refill.
            let input = try StreamBitReader(source: CancellableSource(source), offset: entry.dataOffset,
                                            count: entry.packedSize)
            var crc = CRC32()
            // The decoders hand over output in chunks of at most a few MiB:
            // a cancelled task stops at the next one.
            let checked: ([UInt8]) throws -> Void = { chunk in
                if Task.isCancelled { throw RARError.cancelled }
                crc.update(chunk)
                try sink(chunk)
            }
            if entry.unpackVersion == 29 {
                var state = try unpack ?? Unpack29()
                unpack = nil
                try state.decode(method: entry.method, input: input, outputSize: entry.unpackedSize,
                                 dictionarySize: window, ppmMemoryLimit: limits.maxPPMdMemory,
                                 solid: entry.isSolid, into: checked)
                unpack = state
            } else {
                var state = try unpack50 ?? Unpack50()
                unpack50 = nil
                try state.decode(input: input, outputSize: entry.unpackedSize,
                                 dictionarySize: window,
                                 extraDistance: entry.unpackVersion == RAREntry.unpackVersionRAR7,
                                 solid: entry.isSolid, into: checked)
                unpack50 = state
            }
            if crc.value != expectedCRC { throw RARError.badDataCRC(entry: entry.rawName) }
            failed = false
        }

        private static func canDecode(_ entry: RAREntry) -> Bool { RARDecoder.canDecode(entry) }
    }
}

/// Throws `.cancelled` instead of reading once the current task is cancelled.
private final class CancellableSource: ByteSource {
    private let base: ByteSource

    init(_ base: ByteSource) {
        self.base = base
    }

    var size: UInt64 { base.size }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        if Task.isCancelled { throw RARError.cancelled }
        return try base.read(at: offset, count: count)
    }
}
