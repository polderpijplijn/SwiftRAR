// SPDX-License-Identifier: MIT

import Foundation

/// Destination for the ZIP writer: append, plus patching earlier bytes
/// (local headers get their CRC and sizes once an entry is complete).
public protocol ZIPOutput: AnyObject {
    /// Number of bytes written so far (= offset of the next append).
    var position: UInt64 { get }
    func write(_ bytes: [UInt8]) throws
    func overwrite(at offset: UInt64, with bytes: [UInt8]) throws
}

/// Writes to a new file through `FileHandle`.
public final class FileOutput: ZIPOutput {
    private let handle: FileHandle
    public private(set) var position: UInt64 = 0
    private var isClosed = false

    /// Creates the file; fails if it already exists.
    public init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CBZWriterError.io("\(url.lastPathComponent) already exists")
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CBZWriterError.io("cannot create \(url.lastPathComponent)")
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw CBZWriterError.io(error.localizedDescription)
        }
    }

    deinit {
        try? close()
    }

    public func write(_ bytes: [UInt8]) throws {
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            throw CBZWriterError.io(error.localizedDescription)
        }
        position += UInt64(bytes.count)
    }

    public func overwrite(at offset: UInt64, with bytes: [UInt8]) throws {
        guard offset <= position, UInt64(bytes.count) <= position - offset else {
            throw CBZWriterError.invalidState("patch outside written range")
        }
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: bytes)
            try handle.seek(toOffset: position)
        } catch {
            throw CBZWriterError.io(error.localizedDescription)
        }
    }

    /// Flushes and closes the file. Safe to call more than once.
    public func close() throws {
        guard !isClosed else { return }
        isClosed = true
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            throw CBZWriterError.io(error.localizedDescription)
        }
    }
}

/// Collects the ZIP in memory. Intended for tests and fuzzing.
public final class MemoryOutput: ZIPOutput {
    public private(set) var bytes: [UInt8] = []
    public var position: UInt64 { UInt64(bytes.count) }

    public init() {}

    public func write(_ bytes: [UInt8]) throws {
        self.bytes.append(contentsOf: bytes)
    }

    public func overwrite(at offset: UInt64, with newBytes: [UInt8]) throws {
        guard offset <= position, UInt64(newBytes.count) <= position - offset else {
            throw CBZWriterError.invalidState("patch outside written range")
        }
        let start = Int(offset)
        bytes.replaceSubrange(start..<(start + newBytes.count), with: newBytes)
    }
}
