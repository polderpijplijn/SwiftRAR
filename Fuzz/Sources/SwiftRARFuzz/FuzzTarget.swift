// SPDX-License-Identifier: MIT

import SwiftRAR

/// Tight limits so the fuzzer explores parsing, not memory allocation.
private let fuzzLimits = Limits(
    maxEntries: 256,
    maxEntrySize: 1 << 20,
    maxTotalSize: 4 << 20,
    maxCompressionRatio: 1_000,
    maxNameLength: 512,
    maxDictionarySize: 4 << 20
)

/// libFuzzer entry point. Any input must end in a result or a thrown error;
/// a trap, crash or sanitizer report is a bug.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTestOneInput(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    // The only Unsafe* use in the project: libFuzzer's C ABI hands us a raw
    // pointer. It is copied into an array immediately and never stored.
    let bytes = [UInt8](UnsafeRawBufferPointer(start: start, count: count))
    let source = DataSource(bytes)

    // Header parsing plus every stored entry, as the reader API exposes it.
    if let archive = try? RARArchive(source: source, limits: fuzzLimits) {
        for entry in archive.entries where entry.isStored && !entry.isDirectory {
            try? StoredExtractor.extract(entry, from: source) { _ in }
        }
    }
    // The full conversion path, into memory.
    _ = try? convertToCBZ(source: source, output: MemoryOutput(), limits: fuzzLimits)
    return 0
}
