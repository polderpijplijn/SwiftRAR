// SPDX-License-Identifier: MIT

import Foundation

/// Random-access source of bytes. The archive is never loaded as a whole:
/// parsers and extractors always request a bounded range.
///
/// Implement it to read from somewhere other than a local file. Reads are
/// synchronous and happen on the calling thread. A source is used by one
/// reader or conversion at a time; it does not need to be thread-safe, but
/// must not be shared between tasks unless it is.
public protocol ByteSource: AnyObject {
    /// Total length of the source in bytes.
    var size: UInt64 { get }

    /// Reads exactly `count` bytes starting at `offset`.
    ///
    /// Throws `.truncated` if the range lies outside the source, and
    /// `.corruptHeader` if `count` is negative or larger than `maxReadSize`.
    func read(at offset: UInt64, count: Int) throws -> [UInt8]
}

/// Upper bound per read; keeps an absurd length from a header from turning
/// into a gigantic allocation.
public let maxReadSize = 16 << 20

extension ByteSource {
    /// Validates a read range without overflow.
    @usableFromInline
    func validateRange(offset: UInt64, count: Int) throws {
        guard count >= 0, count <= maxReadSize else {
            throw RARError.corruptHeader("read length \(count) out of range")
        }
        let end = try checkedAdd(offset, UInt64(count))
        guard end <= size else { throw RARError.truncated }
    }
}

/// Reads from a file through `FileHandle`.
///
/// Not thread-safe: every read seeks the one file handle. Do not share an
/// instance between tasks.
public final class FileSource: ByteSource {
    private let handle: FileHandle
    /// File length in bytes, taken when the file was opened.
    public let size: UInt64

    /// Opens `url` for reading. Throws `RARError.io` if it cannot be opened.
    public init(url: URL) throws {
        do {
            handle = try FileHandle(forReadingFrom: url)
            size = try handle.seekToEnd()
        } catch {
            throw RARError.io("cannot open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    deinit {
        try? handle.close()
    }

    public func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        try validateRange(offset: offset, count: count)
        if count == 0 { return [] }
        let data: Data?
        do {
            try handle.seek(toOffset: offset)
            data = try handle.read(upToCount: count)
        } catch {
            throw RARError.io(error.localizedDescription)
        }
        guard let data, data.count == count else { throw RARError.truncated }
        return [UInt8](data)
    }
}

/// Reads from memory. Intended for tests, fuzzing and small archives that
/// are already in memory.
public final class DataSource: ByteSource {
    /// The whole archive.
    public let bytes: [UInt8]
    public var size: UInt64 { UInt64(bytes.count) }

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public convenience init(_ data: Data) {
        self.init([UInt8](data))
    }

    public func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        try validateRange(offset: offset, count: count)
        let start = Int(offset)
        return Array(bytes[start..<(start + count)])
    }
}
