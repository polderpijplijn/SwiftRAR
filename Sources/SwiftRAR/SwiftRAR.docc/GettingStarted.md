# Getting started

Add the package, convert a CBR, or read single files.

## Add the package

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/polderpijplijn/SwiftRAR.git", from: "0.2.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "SwiftRAR", package: "SwiftRAR"),
    ]),
]
```

In Xcode: File > Add Package Dependencies, with the same URL.

SwiftRAR supports iOS 16 and macOS 13 and later, and Swift 6.2 (Xcode 26)
up to the current Xcode.

The `SwiftRAR` product includes decompression code ported from UnRAR, which
is under the unRAR license. Using it means reproducing the unRAR licence
paragraph from `NOTICE` in your app's acknowledgements. The `RARCore` and
`CBZWriter` products are MIT only, but cannot decompress.

## Convert a CBR to a CBZ

```swift
import SwiftRAR

let result = try convertToCBZ(from: cbrURL, to: cbzURL, limits: .default)
print(result.entryCount, result.totalBytes)
```

The whole RAR is validated before anything is written. Output goes to a
temporary file that replaces `cbzURL` only on success. ZIP input is copied
unchanged and is not validated.

The call is synchronous. Run it off the main actor (see <doc:Concurrency>);
cancelling the task it runs in stops it with ``RARError/cancelled``.
`progress` reports the fraction done (0 to 1), once per written entry, on
the converting thread.

## Read single files

```swift
let reader = try RARReader(url: cbrURL, limits: .default)
for entry in reader.entries {
    print(entry.name, entry.size)
}
let firstPage = try reader.data(for: reader.entries[0])
```

``RARReader/data(for:)`` returns the bytes only after their CRC32 matched.
``RARReader/extract(_:into:)`` streams an entry to a closure instead. Those
bytes are provisional until the call returns: on any error, discard what
the closure received.

In a solid archive (``RARReader/isSolid``) an entry depends on the
compressed entries before it. Reading in archive order costs one pass in
total. Going back starts again at the beginning of the entry's stream.

Names are sanitised and unique, but they are keys, not safe file-system
paths. SwiftRAR does not extract to disk; if you do, apply your own
destination, overwrite and symlink policy.

## Other byte sources

Both APIs take any ``ByteSource``. ``FileSource`` reads a file and
``DataSource`` reads bytes in memory. To read from somewhere else, implement
`size` and `read(at:count:)`. Reads are synchronous and bounded in length.

```swift
let reader = try RARReader(source: DataSource(downloadedData), limits: .default)
```

## Limits

``Limits`` is required on every call. ``Limits/default`` suits comic books
on a device with memory to spare: up to 10,000 entries, 256 MiB per entry,
4 GB in total, a compression ratio of 1000:1, a 256 MiB dictionary and
256 MiB of PPMd memory. ``Limits/constrained`` is for apps where memory is
tight, such as on an older iPhone: 64 MiB per entry, a 64 MiB dictionary,
64 MiB of PPMd memory and 8 MiB of headers, the rest as in the default.
RAR4 uses at most a 4 MiB dictionary and WinRAR 5–7 32 MiB by default, so
it still opens almost every comic. Change single properties for other
workloads:

```swift
var limits = Limits.default
limits.maxDictionarySize = 64 << 20
limits.maxTotalSize = 1 << 30
```

An archive that exceeds a bound fails with
``RARError/limitExceeded(_:)``, naming which one.

## Validation stages

**Before any output** (when a ``RARReader`` opens, or before
``convertToCBZ(from:to:limits:progress:)`` writes): format, header CRCs,
encryption and volume flags, compression method, names (length, control
characters, duplicates after sanitising), declared sizes and ratio, and
dictionary size.

**During decoding:** the compressed data itself, the PPMd model size (known
only when a PPMd block starts), and each entry's CRC32, which is known only
once its last byte is decoded.

Every offset and length taken from the input is checked before use, and
truncation, mutation and fuzz testing have found no input that traps. That
is a result of testing, not a proof.

## Memory

Per open reader or running conversion, at most about:

- the LZ window: the dictionary size from the header, but never more than
  the data it can hold (the entry's size, or all compressed entries of a
  solid archive), and at most ``Limits/maxDictionarySize``;
- the PPMd model of a RAR4 text block: at most ``Limits/maxPPMdMemory``;
- all headers: at most ``Limits/maxHeaderBytes``;
- with ``RARReader/data(for:)``, the entry itself: at most
  ``Limits/maxEntrySize``.

That is at most about 784 MiB with ``Limits/default`` and about 200 MiB
with ``Limits/constrained``; a typical comic needs a few tens of MiB. The
limits apply per call, not per process: N imports at the same time can use
N times the budget. On an iPhone, use ``Limits/constrained`` and import one
archive at a time.
