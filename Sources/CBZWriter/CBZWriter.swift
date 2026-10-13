// SPDX-License-Identifier: MIT

import Foundation
import RARCore

public enum CBZWriterError: Error, Equatable, Sendable {
    /// The archive would need ZIP64: an offset or size of 4 GiB or more.
    case zip64Required
    /// More than `CBZWriter.maxEntries` entries (ZIP64 would be needed).
    case tooManyEntries
    /// Empty, absolute, `..`-containing or otherwise unusable entry name.
    case invalidName(String)
    case duplicateName(String)
    /// Calls in the wrong order (e.g. `write` without `beginEntry`).
    case invalidState(String)
    case io(String)
}

/// Writes a ZIP archive of stored (uncompressed) entries, i.e. a CBZ.
///
/// Every entry is streamed: `beginEntry` writes a local header with
/// placeholders, `write` appends data while computing the CRC32, and
/// `endEntry` patches CRC and sizes into the local header. No data
/// descriptors, no ZIP64: anything that would need ZIP64 throws.
/// Names are flagged as UTF-8 (general purpose bit 11).
public final class CBZWriter {
    /// 0xFFFF in the end record means "see ZIP64", so the last usable count is one less.
    public static let maxEntries = 0xFFFE
    /// 0xFFFFFFFF in a size or offset field means "see ZIP64".
    static let maxOffset: UInt64 = 0xFFFF_FFFE

    private struct Record {
        var name: [UInt8]
        var dosTime: UInt32
        var crc: UInt32
        var size: UInt32
        var localHeaderOffset: UInt32
    }

    private struct OpenEntry {
        var record: Record
        var crc = CRC32()
        /// Supplied by the caller, who verified the data itself.
        var verifiedCRC: UInt32?
        var size: UInt64 = 0
    }

    private let output: ZIPOutput
    private var records: [Record] = []
    private var names = Set<String>()
    private var current: OpenEntry?
    private var isFinished = false

    static let versionNeeded: UInt16 = 10    // 1.0: stored entries only
    static let versionMadeBy: UInt16 = 20    // 2.0, MS-DOS attributes
    static let utf8Flag: UInt16 = 0x0800

    public init(output: ZIPOutput) {
        self.output = output
    }

    /// Opens an entry. With `verifiedCRC`, the writer stores that value
    /// instead of computing CRC32 over the data a second time: only for a
    /// caller that checks the very same bytes itself and discards the output
    /// when they do not match (as SwiftRAR's conversion does).
    public func beginEntry(name: String, modified: Date?, verifiedCRC: UInt32? = nil) throws {
        guard !isFinished, current == nil else {
            throw CBZWriterError.invalidState("entry already open or archive finished")
        }
        try Self.validate(name: name)
        guard !names.contains(name) else { throw CBZWriterError.duplicateName(name) }
        guard records.count < Self.maxEntries else { throw CBZWriterError.tooManyEntries }
        guard output.position <= Self.maxOffset else { throw CBZWriterError.zip64Required }

        let record = Record(
            name: Array(name.utf8),
            dosTime: DOSTime.packed(from: modified ?? Date()),
            crc: 0,
            size: 0,
            localHeaderOffset: UInt32(output.position)
        )
        try output.write(Self.localHeader(record))
        names.insert(name)
        current = OpenEntry(record: record, verifiedCRC: verifiedCRC)
    }

    public func write(_ bytes: [UInt8]) throws {
        guard var entry = current else { throw CBZWriterError.invalidState("no open entry") }
        let newSize = try zipChecked(entry.size, UInt64(bytes.count))
        let newEnd = try zipChecked(output.position, UInt64(bytes.count))
        guard newSize <= Self.maxOffset, newEnd <= Self.maxOffset else {
            throw CBZWriterError.zip64Required
        }
        try output.write(bytes)
        if entry.verifiedCRC == nil { entry.crc.update(bytes) }
        entry.size = newSize
        current = entry
    }

    /// Closes the open entry and returns the CRC32 of its data.
    @discardableResult
    public func endEntry() throws -> UInt32 {
        guard var entry = current else { throw CBZWriterError.invalidState("no open entry") }
        entry.record.crc = entry.verifiedCRC ?? entry.crc.value
        entry.record.size = UInt32(entry.size)
        // CRC-32, compressed size, uncompressed size live at offset 14 of the local header.
        var patch: [UInt8] = []
        patch.appendLE(entry.record.crc)
        patch.appendLE(entry.record.size)
        patch.appendLE(entry.record.size)
        try output.overwrite(at: UInt64(entry.record.localHeaderOffset) + 14, with: patch)
        records.append(entry.record)
        current = nil
        return entry.record.crc
    }

    /// Convenience: one complete entry from a buffer.
    public func addEntry(name: String, modified: Date?, contents: [UInt8]) throws {
        try beginEntry(name: name, modified: modified)
        try write(contents)
        try endEntry()
    }

    /// Writes the central directory and the end record.
    public func finish() throws {
        guard !isFinished, current == nil else {
            throw CBZWriterError.invalidState("entry still open or archive finished")
        }
        let directoryOffset = output.position
        guard directoryOffset <= Self.maxOffset else { throw CBZWriterError.zip64Required }
        for record in records {
            try output.write(Self.centralHeader(record))
        }
        let directorySize = output.position - directoryOffset
        guard output.position <= Self.maxOffset else { throw CBZWriterError.zip64Required }

        var end: [UInt8] = []
        end.appendLE(UInt32(0x0605_4B50))
        end.appendLE(UInt16(0))                     // number of this disk
        end.appendLE(UInt16(0))                     // disk with central directory
        end.appendLE(UInt16(records.count))         // entries on this disk
        end.appendLE(UInt16(records.count))         // total entries
        end.appendLE(UInt32(directorySize))
        end.appendLE(UInt32(directoryOffset))
        end.appendLE(UInt16(0))                     // comment length
        try output.write(end)
        isFinished = true
    }

    // MARK: - Encoding

    private static func localHeader(_ r: Record) -> [UInt8] {
        var h: [UInt8] = []
        h.appendLE(UInt32(0x0403_4B50))
        h.appendLE(versionNeeded)
        h.appendLE(utf8Flag)
        h.appendLE(UInt16(0))                        // method: stored
        h.appendLE(r.dosTime)                        // time (low) + date (high)
        h.appendLE(r.crc)
        h.appendLE(r.size)                           // compressed size
        h.appendLE(r.size)                           // uncompressed size
        h.appendLE(UInt16(r.name.count))
        h.appendLE(UInt16(0))                        // extra length
        h.append(contentsOf: r.name)
        return h
    }

    private static func centralHeader(_ r: Record) -> [UInt8] {
        var h: [UInt8] = []
        h.appendLE(UInt32(0x0201_4B50))
        h.appendLE(versionMadeBy)
        h.appendLE(versionNeeded)
        h.appendLE(utf8Flag)
        h.appendLE(UInt16(0))                        // method: stored
        h.appendLE(r.dosTime)
        h.appendLE(r.crc)
        h.appendLE(r.size)
        h.appendLE(r.size)
        h.appendLE(UInt16(r.name.count))
        h.appendLE(UInt16(0))                        // extra length
        h.appendLE(UInt16(0))                        // comment length
        h.appendLE(UInt16(0))                        // disk number start
        h.appendLE(UInt16(0))                        // internal attributes
        h.appendLE(UInt32(0))                        // external attributes
        h.appendLE(r.localHeaderOffset)
        h.append(contentsOf: r.name)
        return h
    }

    /// Writer-side name check (defence in depth; SwiftRAR sanitises first).
    static func validate(name: String) throws {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 0xFFFF else { throw CBZWriterError.invalidName(name) }
        guard !name.hasPrefix("/"), !name.contains("\\") else { throw CBZWriterError.invalidName(name) }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw CBZWriterError.invalidName(name)
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw CBZWriterError.invalidName(name)
        }
    }

    private func zipChecked(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        if overflow { throw CBZWriterError.zip64Required }
        return sum
    }
}

extension Array where Element == UInt8 {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}
