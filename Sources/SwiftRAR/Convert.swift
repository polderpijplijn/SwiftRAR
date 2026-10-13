// SPDX-License-Identifier: MIT

import Foundation
@_exported import CBZWriter
@_exported import RARCore
import RARDecode

/// Result of a successful conversion.
public struct ConversionResult: Equatable, Sendable {
    public var sourceFormat: ArchiveFormat
    /// Number of files written to the CBZ (0 for a ZIP copied as-is).
    public var entryCount: Int
    /// Total unpacked bytes written (the copied size for a ZIP).
    public var totalBytes: UInt64
}

/// Converts a CBR (RAR4/RAR5) or CBZ (ZIP) file to a CBZ at `destination`.
///
/// - ZIP input is copied unchanged, up to `limits.maxTotalSize`. It is
///   **not validated**: its structure, names, sizes and CRCs are the
///   caller's to check when it reads the CBZ. A successful conversion of a
///   ZIP says nothing about it being a valid archive.
/// - RAR input is validated completely (limits, names, methods) before
///   anything is written, then streamed entry by entry into a stored ZIP.
///
/// Output goes to a temporary file next to `destination` that replaces it only
/// on success; on any error (including a CRC mismatch) the partial file is
/// deleted and an existing `destination` is left untouched.
///
/// `progress` receives the fraction of the archive processed so far, from 0
/// to 1: once per written entry for RAR, once per copied chunk for ZIP. It is
/// called on the converting thread; the last call is 1 on success.
@discardableResult
public func convertToCBZ(from source: URL, to destination: URL, limits: Limits,
                         progress: ((Double) -> Void)? = nil) throws -> ConversionResult {
    let input = try FileSource(url: source)
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")

    let output = try FileOutput(url: temporary)
    do {
        let result = try convertToCBZ(source: input, output: output, limits: limits, progress: progress)
        try output.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return result
    } catch {
        try? output.close()
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
}

/// Stream-level conversion; the URL variant above is a thin wrapper.
/// On error, `output` holds partial data that the caller must discard.
///
/// Runs synchronously. Inside a `Task`, cancelling the task stops the work
/// at the next header or output chunk with `RARError.cancelled`.
@discardableResult
public func convertToCBZ(source: ByteSource, output: ZIPOutput, limits: Limits,
                         progress: ((Double) -> Void)? = nil) throws -> ConversionResult {
    let format = try ArchiveFormat.detect(source)
    if format == .zip {
        return try copyZIP(source, to: output, limits: limits, progress: progress)
    }

    let archive = try RARArchive(source: source, limits: limits)
    let plan = try planExtraction(archive, limits: limits)

    let writer = CBZWriter(output: output)
    // One session for the archive: a solid entry continues from the one
    // before it. Links are skipped safely: RAR4 stores a link target raw
    // (UnRAR reads it from the packed data), so it is never part of the
    // solid stream; RAR5 keeps it in a header record.
    let session = RARDecoder.Session(archive: archive, limits: limits)
    var total: UInt64 = 0
    for (index, (entry, name)) in plan.enumerated() {
        // The extractors verify the CRC of exactly these bytes and throw on a
        // mismatch, so the writer takes it over instead of a second pass
        // (about a quarter of the conversion time).
        try writer.beginEntry(name: name, modified: entry.modified, verifiedCRC: entry.crc32)
        let sink: ([UInt8]) throws -> Void = { try writer.write($0) }
        if entry.isStored {
            try StoredExtractor.extract(entry, from: source, into: sink)
        } else {
            try session.decode(entry, from: source, into: sink)
        }
        try writer.endEntry()
        total = try checkedAdd(total, entry.unpackedSize)
        if let progress {
            // Measured by position in the archive: packed bytes are what the
            // work is proportional to. The last entry reports exactly 1.
            let end = entry.dataOffset.addingReportingOverflow(entry.packedSize)
            let fraction = source.size == 0 || end.overflow ? 1 : min(1, Double(end.partialValue) / Double(source.size))
            progress(index == plan.count - 1 ? 1 : fraction)
        }
    }
    try writer.finish()
    return ConversionResult(sourceFormat: format, entryCount: plan.count, totalBytes: total)
}

/// Checks every entry before a single byte is written, and maps each one to a
/// sanitised, unique name. Directories and links are skipped.
func planExtraction(_ archive: RARArchive, limits: Limits) throws -> [(RAREntry, String)] {
    var plan: [(RAREntry, String)] = []
    var names = Set<String>()
    var total: UInt64 = 0

    for entry in archive.entries where !entry.isDirectory && !entry.isLink {
        if entry.isEncrypted { throw RARError.encrypted }
        if entry.isSplit { throw RARError.multiVolume }
        if !entry.isStored {
            guard RARDecoder.canDecode(entry) else {
                throw RARError.unsupportedCompression(method: entry.method)
            }
            if entry.dictionarySize > limits.maxDictionarySize {
                throw RARError.limitExceeded(.dictionarySize)
            }
        }
        guard entry.crc32 != nil else { throw RARError.missingChecksum(entry: entry.rawName) }

        if entry.unpackedSize > limits.maxEntrySize { throw RARError.limitExceeded(.entrySize) }
        let (maxUnpacked, overflow) = entry.packedSize.multipliedReportingOverflow(by: limits.maxCompressionRatio)
        if !overflow && entry.unpackedSize > maxUnpacked {
            throw RARError.limitExceeded(.compressionRatio)
        }
        total = try checkedAdd(total, entry.unpackedSize)
        if total > limits.maxTotalSize { throw RARError.limitExceeded(.totalSize) }

        let name = try NameSanitizer.sanitize(entry.rawName, maxLength: limits.maxNameLength)
        guard names.insert(name).inserted else { throw RARError.duplicateEntryName(name) }
        plan.append((entry, name))
    }

    if plan.isEmpty { throw RARError.emptyArchive }
    if plan.count > CBZWriter.maxEntries { throw CBZWriterError.tooManyEntries }
    return plan
}

private func copyZIP(_ source: ByteSource, to output: ZIPOutput, limits: Limits,
                     progress: ((Double) -> Void)?) throws -> ConversionResult {
    guard source.size <= limits.maxTotalSize else { throw RARError.limitExceeded(.totalSize) }
    let chunk: UInt64 = 1 << 20
    var offset: UInt64 = 0
    while offset < source.size {
        if Task.isCancelled { throw RARError.cancelled }
        let count = Int(min(chunk, source.size - offset))
        try output.write(try source.read(at: offset, count: count))
        offset += UInt64(count)
        progress?(Double(offset) / Double(source.size))
    }
    if source.size == 0 { progress?(1) }
    return ConversionResult(sourceFormat: .zip, entryCount: 0, totalBytes: source.size)
}
