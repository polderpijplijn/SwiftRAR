// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

    /// Atomically creates and opens the file; fails if the path already
    /// exists, including a symlink. The parent directory must be trusted.
    public init(url: URL) throws {
        // Keep the descriptor returned by exclusive creation: reopening
        // the path would allow another process to replace it with a link.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o666))
        guard descriptor >= 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            throw CBZWriterError.io("cannot create \(url.lastPathComponent): \(error.localizedDescription)")
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
