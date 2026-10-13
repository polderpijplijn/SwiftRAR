// SPDX-License-Identifier: MIT

/// A parsed RAR4 or RAR5 archive: format, archive flags and file entries.
///
/// Opening reads only headers; entry data stays in the source until it is
/// extracted. Archive-level encryption and multi-volume sets are rejected
/// here; per-entry conditions are left to the caller (see `SwiftRAR`).
///
/// This is the metadata layer of the MIT-only `RARCore` product. Most apps
/// want `RARReader` or `convertToCBZ` from `SwiftRAR` instead, which apply
/// every safety check. Not thread-safe, because its `source` is not.
public final class RARArchive {
    /// The source the headers were read from; entry data is read from it too.
    public let source: ByteSource
    /// `.rar4` or `.rar5`.
    public let format: ArchiveFormat
    /// Whether the archive flag says solid.
    public let isSolid: Bool
    /// Every file header in archive order, directories and links included,
    /// with names as stored (not sanitised).
    public let entries: [RAREntry]

    /// Parses the headers. Throws for an unknown format, an encrypted or
    /// multi-volume archive, a corrupt header or an exceeded limit.
    public init(source: ByteSource, limits: Limits) throws {
        let format = try ArchiveFormat.detect(source)
        let parsed: (entries: [RAREntry], isSolid: Bool)
        switch format {
        case .rar4: parsed = try RAR4Parser.parse(source, limits: limits)
        case .rar5: parsed = try RAR5Parser.parse(source, limits: limits)
        case .zip: throw RARError.unknownFormat
        }
        self.source = source
        self.format = format
        self.isSolid = parsed.isSolid
        self.entries = parsed.entries
    }
}

/// Extracts entries stored without compression (RAR4 method 0x30, RAR5 method 0).
public enum StoredExtractor {
    public static let chunkSize = 1 << 16

    /// Streams the entry's data to `sink` in chunks and verifies its CRC32.
    ///
    /// On a CRC mismatch the data has already reached `sink`; the caller must
    /// discard its output (SwiftRAR deletes the partial file).
    public static func extract(
        _ entry: RAREntry,
        from source: ByteSource,
        into sink: ([UInt8]) throws -> Void
    ) throws {
        guard entry.isStored else { throw RARError.unsupportedCompression(method: entry.method) }
        guard !entry.isEncrypted else { throw RARError.encrypted }
        guard !entry.isSplit else { throw RARError.multiVolume }
        guard let expectedCRC = entry.crc32 else { throw RARError.missingChecksum(entry: entry.rawName) }
        guard entry.packedSize == entry.unpackedSize else {
            throw RARError.corruptHeader("stored entry with packed size != unpacked size")
        }
        let end = try checkedAdd(entry.dataOffset, entry.packedSize)
        guard end <= source.size else { throw RARError.truncated }

        var crc = CRC32()
        var offset = entry.dataOffset
        while offset < end {
            if Task.isCancelled { throw RARError.cancelled }
            let count = Int(min(UInt64(chunkSize), end - offset))
            let chunk = try source.read(at: offset, count: count)
            crc.update(chunk)
            try sink(chunk)
            offset += UInt64(count)
        }
        if crc.value != expectedCRC { throw RARError.badDataCRC(entry: entry.rawName) }
    }
}
