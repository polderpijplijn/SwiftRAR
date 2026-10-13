// SPDX-License-Identifier: MIT

import Foundation
import RARDecode

/// Lists the files of a RAR4 or RAR5 archive and extracts them one at a time,
/// without creating a ZIP.
///
/// Opening reads only the headers and applies the same checks as
/// `convertToCBZ`: an encrypted, split or unsupported file, a bad or
/// duplicate name, or any bound in `Limits` makes the whole archive fail to
/// open. An archive that converts also reads, and the other way round.
///
/// **Random access.** In a non-solid archive every entry decodes on its own.
/// In a solid archive an entry needs all compressed entries before it in its
/// stream: reading in archive order costs one pass in total, while going
/// back costs a pass from the start of the stream (`isSolid` tells which).
/// Stored entries are always read directly.
///
/// **Errors.** After any error, including a CRC mismatch or cancellation,
/// the reader stays usable: the next `extract` starts from the beginning of
/// that entry's stream again.
///
/// **Concurrency.** Not thread-safe: the source and the decoder session hold
/// mutable state. Use one reader per task; open a second reader to read in
/// parallel. Cancelling the surrounding `Task` stops the work at the next
/// output chunk or input read with `RARError.cancelled`.
public final class RARReader {
    /// A file in the archive.
    public struct Entry: Equatable, Sendable {
        /// Position in `entries`.
        public let index: Int
        /// Sanitised and unique within the archive. A key, not a safe path.
        public let name: String
        /// The name as stored in the archive.
        public let rawName: String
        /// Unpacked size in bytes.
        public let size: UInt64
        public let modified: Date?
        public let isCompressed: Bool
    }

    public let format: ArchiveFormat
    public let isSolid: Bool
    /// Files only, in archive order: no directories and no links.
    public let entries: [Entry]

    private let source: ByteSource
    private let archive: RARArchive
    private let limits: Limits
    /// The archive entry behind each element of `entries`.
    private let rarEntries: [RAREntry]
    /// For each entry, its position among the compressed entries (the
    /// decoder stream), or nil when it is stored.
    private let streamPosition: [Int?]
    /// The compressed entries in archive order.
    private let stream: [RAREntry]

    private var session: RARDecoder.Session?
    /// The stream position `session` continues with; nil without a session.
    private var cursor: Int?
    /// Compressed entries decoded so far, skipped ones included (for tests).
    private(set) var decodedEntries = 0

    public init(source: ByteSource, limits: Limits) throws {
        let archive = try RARArchive(source: source, limits: limits)
        let plan = try planExtraction(archive, limits: limits)

        var entries: [Entry] = []
        var positions: [Int?] = []
        var stream: [RAREntry] = []
        for (index, (entry, name)) in plan.enumerated() {
            entries.append(Entry(index: index, name: name, rawName: entry.rawName, size: entry.unpackedSize,
                                 modified: entry.modified, isCompressed: !entry.isStored))
            if entry.isStored {
                positions.append(nil)
            } else {
                positions.append(stream.count)
                stream.append(entry)
            }
        }
        self.source = source
        self.archive = archive
        self.limits = limits
        self.format = archive.format
        self.isSolid = archive.isSolid
        self.entries = entries
        self.rarEntries = plan.map(\.0)
        self.streamPosition = positions
        self.stream = stream
    }

    public convenience init(url: URL, limits: Limits) throws {
        try self.init(source: FileSource(url: url), limits: limits)
    }

    /// Streams one entry to `sink` and verifies its CRC32.
    ///
    /// The bytes are provisional until this returns: on any error the caller
    /// must discard what `sink` received. An entry of another reader throws
    /// `.invalidEntryName`.
    public func extract(_ entry: Entry, into sink: ([UInt8]) throws -> Void) throws {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw RARError.invalidEntryName(entry.name)
        }
        guard let position = streamPosition[entry.index] else {
            return try StoredExtractor.extract(rarEntries[entry.index], from: source, into: sink)
        }

        // A compressed entry without the solid flag starts a new stream.
        var restart = position
        while restart > 0 && stream[restart].isSolid { restart -= 1 }

        // Continue the current session when it is in the same stream and not
        // past this entry; otherwise start fresh at the restart point.
        let session: RARDecoder.Session
        let start: Int
        if let current = self.session, let cursor, cursor >= restart, cursor <= position {
            session = current
            start = cursor
        } else {
            session = RARDecoder.Session(archive: archive, limits: limits)
            self.session = session
            start = restart
        }

        do {
            for skipped in start..<position {
                decodedEntries += 1
                try session.decode(stream[skipped], from: source) { _ in }
                cursor = skipped + 1
            }
            decodedEntries += 1
            try session.decode(stream[position], from: source, into: sink)
            cursor = position + 1
        } catch {
            self.session = nil
            cursor = nil
            throw error
        }
    }

    /// The whole entry in memory, returned only after its CRC32 matched.
    /// Meant for small entries such as a comic page; `size` is bounded by
    /// `Limits.maxEntrySize`.
    public func data(for entry: Entry) throws -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(clamping: min(entry.size, 64 << 20)))
        try extract(entry) { bytes += $0 }
        return Data(bytes)
    }
}
