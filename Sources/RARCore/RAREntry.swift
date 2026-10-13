// SPDX-License-Identifier: MIT

import Foundation

/// One file header from a RAR4 or RAR5 archive.
///
/// Metadata only; the data lives at `dataOffset` in the source and is read
/// only when extracting.
public struct RAREntry: Equatable, Sendable {
    /// Name as stored in the archive, not yet sanitised. Never use it as a
    /// path directly: see `NameSanitizer`.
    public var rawName: String
    public var packedSize: UInt64
    public var unpackedSize: UInt64
    /// CRC32 of the unpacked data, if the archive provides one.
    public var crc32: UInt32?
    /// 0 = store, 1...5 = compression level (RAR4 0x31...0x35, RAR5 1...5).
    public var method: Int
    /// RAR4: UnpVer (e.g. 29). RAR5 archives: 50 for the RAR 5.0 algorithm
    /// (also RAR7 headers with the compat flag), 70 for RAR 7.0, as in UnRAR.
    public var unpackVersion: Int
    /// Dictionary size the decoder needs for this entry.
    public var dictionarySize: UInt64
    public var isDirectory: Bool
    public var isEncrypted: Bool
    /// Data continues from a previous or into a next volume.
    public var isSplit: Bool
    /// Entry depends on the window of the previous entry (solid).
    public var isSolid: Bool
    /// Symlink, hard link or other redirection; never extracted.
    public var isLink: Bool
    public var modified: Date?
    /// Absolute position of the (packed) data in the source.
    public var dataOffset: UInt64

    public var isStored: Bool { method == 0 }

    /// `unpackVersion` of RAR5 archives, as UnRAR's VER_PACK5 and VER_PACK7.
    public static let unpackVersionRAR5 = 50
    public static let unpackVersionRAR7 = 70

    public init(
        rawName: String,
        packedSize: UInt64,
        unpackedSize: UInt64,
        crc32: UInt32?,
        method: Int,
        unpackVersion: Int,
        dictionarySize: UInt64,
        isDirectory: Bool,
        isEncrypted: Bool,
        isSplit: Bool,
        isSolid: Bool,
        isLink: Bool,
        modified: Date?,
        dataOffset: UInt64
    ) {
        self.rawName = rawName
        self.packedSize = packedSize
        self.unpackedSize = unpackedSize
        self.crc32 = crc32
        self.method = method
        self.unpackVersion = unpackVersion
        self.dictionarySize = dictionarySize
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
        self.isSplit = isSplit
        self.isSolid = isSolid
        self.isLink = isLink
        self.modified = modified
        self.dataOffset = dataOffset
    }
}
