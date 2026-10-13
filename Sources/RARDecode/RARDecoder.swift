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
/// Phase 1 stub: no compressed method is supported yet. Later phases add
/// unpack29 (RAR4 LZ), RAR4 filters, PPMd variant H and unpack50 (RAR5).
public enum RARDecoder {
    /// Whether this decoder can unpack the entry.
    public static func canDecode(_ entry: RAREntry) -> Bool {
        false
    }

    /// Unpacks a compressed entry, streaming the output to `sink`, and
    /// verifies its CRC32.
    public static func decode(
        _ entry: RAREntry,
        from source: ByteSource,
        limits: Limits,
        into sink: ([UInt8]) throws -> Void
    ) throws {
        throw RARError.unsupportedCompression(method: entry.method)
    }
}
