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
    fuzzReader(source, bytes)
    return 0
}

/// `RARReader`: every entry in archive order, alternating `extract` and
/// `data(for:)`, continuing after errors as the API promises. Then up to
/// eight more reads in an order taken from the input, which go back in a
/// solid stream, repeat entries and abort some halfway through by throwing
/// from the sink. Each read costs at most one pass over the stream.
private func fuzzReader(_ source: DataSource, _ bytes: [UInt8]) {
    guard let reader = try? RARReader(source: source, limits: fuzzLimits) else { return }
    let entries = reader.entries
    for entry in entries {
        if entry.index.isMultiple(of: 2) {
            try? reader.extract(entry) { _ in }
        } else {
            _ = try? reader.data(for: entry)
        }
    }
    guard !entries.isEmpty else { return }

    // The order comes from a hash of the whole input rather than from bytes
    // set aside for it, so every seed stays a valid archive and every
    // mutation reads in a different order.
    var random = SplitMix64(seed: fnv1a(bytes))
    for _ in 0..<min(entries.count + 1, 8) {
        let choice = random.next()
        let entry = entries[Int(choice % UInt64(entries.count))]
        switch (choice >> 32) % 4 {
        case 0:
            _ = try? reader.data(for: entry)
        case 1:
            // A sink error drops the session; the next read must start over.
            try? reader.extract(entry) { _ in throw Abort() }
        default:
            try? reader.extract(entry) { _ in }
        }
    }

    // An entry of another reader over the same bytes must be refused.
    if let other = try? RARReader(source: source, limits: fuzzLimits), let entry = other.entries.first {
        try? reader.extract(entry) { _ in }
    }
}

private struct Abort: Error {}

private func fnv1a(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
    return hash
}

/// A small deterministic generator, so a crash input replays the same order.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
