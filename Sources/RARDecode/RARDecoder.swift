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
/// Supported so far: RAR4 UnpVer 29 (LZ + Huffman), non-solid, without
/// filters or PPMd blocks. Later phases add RAR4 filters and solid archives,
/// PPMd variant H and unpack50 (RAR5).
public enum RARDecoder {
    /// Whether this decoder can unpack the entry. Filters and PPMd blocks only
    /// show up inside the data; `decode` throws `.unsupportedCompression` then.
    public static func canDecode(_ entry: RAREntry) -> Bool {
        !entry.isStored && !entry.isSolid && !entry.isEncrypted && !entry.isSplit
            && entry.unpackVersion == 29
    }

    /// Unpacks a compressed entry, streaming the output to `sink`, and
    /// verifies its CRC32.
    ///
    /// On an error the data written so far has already reached `sink`; the
    /// caller must discard its output (SwiftRAR deletes the partial file).
    public static func decode(
        _ entry: RAREntry,
        from source: ByteSource,
        limits: Limits,
        into sink: ([UInt8]) throws -> Void
    ) throws {
        guard !entry.isEncrypted else { throw RARError.encrypted }
        guard !entry.isSplit else { throw RARError.multiVolume }
        guard canDecode(entry) else { throw RARError.unsupportedCompression(method: entry.method) }
        guard let expectedCRC = entry.crc32 else { throw RARError.missingChecksum(entry: entry.rawName) }
        guard entry.dictionarySize <= limits.maxDictionarySize else { throw RARError.limitExceeded(.dictionarySize) }
        guard entry.unpackedSize <= limits.maxEntrySize else { throw RARError.limitExceeded(.entrySize) }

        let input = try StreamBitReader(source: source, offset: entry.dataOffset, count: entry.packedSize)
        var unpack = try Unpack29(method: entry.method, input: input,
                                  outputSize: entry.unpackedSize, dictionarySize: entry.dictionarySize)
        var crc = CRC32()
        try unpack.run { chunk in
            crc.update(chunk)
            try sink(chunk)
        }
        if crc.value != expectedCRC { throw RARError.badDataCRC(entry: entry.rawName) }
    }
}
