# SwiftRAR

A pure-Swift RAR reader and CBZ writer for iOS and macOS. It lists and
extracts the files of RAR4 and RAR5 archives, and converts CBR comic
archives into CBZ (stored ZIP), entirely in Swift: no C/C++, no libarchive,
no other dependencies. Built for Grim Reader, usable in any app that
imports documents, browses archives or reads comics.

SwiftRAR is a reader only. It never creates RAR archives.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/polderpijplijn/SwiftRAR.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "SwiftRAR", package: "SwiftRAR"),
    ]),
]
```

Or in Xcode: File > Add Package Dependencies, with the same URL.

- **Platforms:** iOS 16, macOS 13 and later.
- **Toolchains:** Swift 5.9 (Xcode 15.2) up to the current Xcode, both
  tested in CI, with Swift 6 strict concurrency checking.

## Products and licenses

| Product     | You get | Licenses you take on |
|-------------|---------|----------------------|
| `SwiftRAR`  | `convertToCBZ`, `RARReader`, plus everything in RARCore and CBZWriter | MIT **and** the unRAR license |
| `RARCore`   | format detection, headers and listing (`RARArchive`), stored entries, `Limits`, `RARError`; **no decompression** | MIT |
| `CBZWriter` | streaming stored-ZIP writer | MIT |

The `SwiftRAR` product's own code is MIT, but it links the internal
RARDecode target: a Swift port of RARLAB's UnRAR decompression code, under
the unRAR license. That licence allows the code to be used to handle RAR
archives free of charge, but forbids using it to build a RAR-compatible
archiver or to re-create the RAR compression algorithm. If your app uses
the `SwiftRAR` product, include the unRAR licence paragraph from
[`NOTICE`](NOTICE) in its acknowledgements. Details: [License](#license).

## Quick start

Convert a CBR to a CBZ:

```swift
import SwiftRAR

let result = try convertToCBZ(from: cbrURL, to: cbzURL, limits: .default)
```

RAR input is fully validated before anything is written. Output goes to a
temporary file that replaces the destination only on success. ZIP input is
copied unchanged (up to `maxTotalSize`) and is **not validated**: check it
when you read the CBZ.

Read single files without creating a ZIP:

```swift
let reader = try RARReader(url: cbrURL, limits: .default)
for entry in reader.entries {
    print(entry.name, entry.size, entry.isCompressed)
}
let page = try reader.data(for: reader.entries[0])   // returned only after its CRC32 matched
```

`RARReader` accepts exactly the archives `convertToCBZ` accepts.
`extract(_:into:)` streams an entry to a closure instead; those bytes are
provisional until it returns, so discard them on any error. In a solid
archive (`isSolid`) an entry needs the compressed entries before it: reading
in order costs one pass, going back starts again at the beginning of the
stream. After an error or cancellation the reader stays usable. Names are
sanitised and unique, but they are keys, not safe paths: SwiftRAR does not
extract to disk.

Both APIs also take any `ByteSource` (`FileSource`, `DataSource`, or your
own) instead of a URL.

Full documentation is in the DocC catalog (`Sources/SwiftRAR/SwiftRAR.docc`;
Xcode shows it under Product > Build Documentation). Two samples build in
CI: [`Examples/ListAndExtract`](Examples/ListAndExtract) (command line) and
[`Examples/SwiftUIConvert`](Examples/SwiftUIConvert) (SwiftUI, with
progress and cancellation).

## What is supported

| Input | Result |
|-------|--------|
| RAR4 / RAR5, stored entries (`-m0`) | read and converted, CRC32 verified |
| RAR4 compressed (`-m1`...`-m5`), solid or not, standard filters, PPMd (`-mct`) | read and converted, CRC32 verified |
| RAR5 compressed (RAR 5.0 and 7.0 algorithms), solid or not, its four filters | read and converted, CRC32 verified |
| ZIP / CBZ | copied unchanged by `convertToCBZ`, **not validated**; `RARReader` rejects it (`.unknownFormat`) |
| RAR4 names with the Unicode flag | the legacy (OEM/ANSI) name is used, which may differ from what WinRAR shows |
| RAR5 entries checked by BLAKE2sp only (`rar -htb`) | `RARError.missingChecksum` |
| RAR4 with non-standard RarVM programs | `RARError.unsupportedCompression` |
| RAR 2.x compression (UnpVer 20/26) | `RARError.unsupportedCompression` |
| Encrypted archives or entries | `RARError.encrypted` |
| Multi-volume archives | `RARError.multiVolume` |
| RAR 1.4 | `RARError.unsupportedFormat` |
| SFX archives | not recognised (`RARError.unknownFormat`) |
| CBZ output of 4 GiB or more, or more than 65,534 entries (ZIP64) | `CBZWriterError` |

## Validation

**Before any output** (when `RARReader` opens, or before `convertToCBZ`
writes): format, header CRCs, encryption and volume flags, compression
method, names (length, control characters, duplicates after sanitising),
declared sizes and compression ratio, dictionary size, and every bound in
`Limits` that headers can reveal.

**During decoding:** the compressed data itself, the PPMd model size (known
only when a PPMd block starts), and each entry's CRC32, which is known only
once its last byte is decoded. On a mismatch the partial output is deleted
(`convertToCBZ`) or must be discarded (`extract`).

Every offset and length taken from the input is checked before use, with
overflow-checked arithmetic, and every failure is thrown as an error.
Truncation and mutation tests on every fixture, and libFuzzer runs after
every decoder change, have found no input that traps. That is a result of
testing, not a proof.

## Limits and memory

`Limits` is required on every call. `Limits.default` suits comic books on
an iPhone:

| Bound | Default |
|-------|---------|
| `maxEntries` | 10,000 |
| `maxEntrySize` | 256 MiB |
| `maxTotalSize` | 4,000,000,000 bytes (under the ZIP64 limit) |
| `maxCompressionRatio` | 1000:1 per entry |
| `maxNameLength` | 1,024 UTF-8 bytes |
| `maxDictionarySize` | 256 MiB |
| `maxPPMdMemory` | 256 MiB |
| `maxHeaderBytes` | 16 MiB |

Memory per open reader or running conversion is at most about: the LZ
window (the header's dictionary size, but never more than the data it can
hold, and at most `maxDictionarySize`), plus the PPMd model of a RAR4 text
block (at most `maxPPMdMemory`), plus the headers (at most
`maxHeaderBytes`), plus, with `RARReader.data(for:)`, the entry itself (at
most `maxEntrySize`). A typical comic needs a few tens of MiB.

These bounds apply **per call, not per process**: N imports at the same
time can use N times the budget. On an iPhone, import one archive at a
time, or tighten the limits for parallel imports. Solid RAR5 archives with
near-identical files can exceed the 1000:1 ratio; loosen
`maxCompressionRatio` if your content needs it.

## Concurrency

- `convertToCBZ` and `RARReader` are synchronous. Run them off the main
  actor: a `Task {}` started from a view inherits the main actor, so use a
  detached task and forward cancellation to it (see `Examples/SwiftUIConvert`
  and the Concurrency article in the docs).
- Cancelling the task stops the work at the next header, output chunk or
  input read with `RARError.cancelled`.
- `progress` (fraction 0 to 1, once per written entry) and the `extract`
  sink are called synchronously on the working thread.
- Conversions of different files may run in parallel. `RARReader`,
  `RARArchive`, `FileSource`, `DataSource` and `CBZWriter` are not
  thread-safe and not `Sendable`: use one instance per task.

## Errors

Everything throws `RARError`, and conversion also `CBZWriterError`. Both
have a `category`:

| Category | Meaning | Typical response |
|----------|---------|------------------|
| `.corrupt` | damaged, truncated or not an archive | report a damaged file |
| `.unsupported` | a valid archive with an unsupported feature (password, volumes, method, BLAKE2sp) | report "not supported" |
| `.limit` | a bound in `Limits`, or the ZIP64 limit | report "too large", or retry with looser limits |
| `.io` | reading or writing a file failed | report, maybe retry |
| `.cancelled` | the task was cancelled | nothing |
| `.usage` | the API was called incorrectly (direct `CBZWriter` use) | fix the calling code |

Every case is listed in the "Handling errors" article in the docs.

## Safety

- No `Unsafe*` pointers in the package (the only exception is the libFuzzer
  entry point in `Fuzz/`, which is not part of the package).
- Names are sanitised: `\` becomes `/`; `.`, `..`, empty components and
  drive letters are removed; control characters are rejected.
- Streaming I/O through `ByteSource`: the archive is never loaded into
  memory as a whole, and a single read is capped at 16 MiB.
- The LZ window is never larger than the data it can hold, even when the
  header asks for a larger dictionary.

## Versioning

SwiftRAR follows [Semantic Versioning](https://semver.org) with three-part
tags (`0.1.0`), as SwiftPM requires. While the version is 0.x, a minor
release may change the API; the [changelog](CHANGELOG.md) says what changed
and which UnRAR version RARDecode follows.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities privately as
described in [SECURITY.md](SECURITY.md), not in a public issue.

## License

SwiftRAR is split-licensed:

- **RARCore, CBZWriter, SwiftRAR** (and tests, tools, fuzz harness): MIT,
  see [`LICENSE`](LICENSE).
- **RARDecode**: the unRAR license, see
  [`Sources/RARDecode/LICENSE-UNRAR`](Sources/RARDecode/LICENSE-UNRAR) (the
  unmodified licence from UnRAR 7.3.1). RARDecode ports RARLAB's UnRAR
  decompression code.

The `SwiftRAR` product depends on RARDecode, so an app using it is bound by
both licenses; `RARCore` and `CBZWriter` alone are MIT only. Details are in
[`NOTICE`](NOTICE). The UnRAR source is not in this repository.

## Testing

```sh
swift test
```

- **Oracle**: `Tools/oracle/build-unrar.sh` prints the path of an official
  `unrar`. It uses `$SWIFTRAR_UNRAR` or one on `PATH`, or otherwise downloads
  and builds UnRAR from RARLAB's source into `Tools/oracle/.build`. The tests
  convert archives with SwiftRAR and compare the result byte for byte with
  `unrar x`. Tests that need the oracle are skipped when it is missing, unless
  `SWIFTRAR_REQUIRE_ORACLE=1` is set (as in CI), which turns a skip into a failure.
- **Fixtures**: `Tests/Fixtures/{rar4,rar5}-{m0,m3,s,mct}.rar` plus
  `rar4-m3-{md64,big,flt}.rar`, `rar4-flt-{e8,audio,delta,rgb}.rar` and
  `rar4-s-{flt,link}.rar`, `rar4-mct-{s,mix,mem,flt,rep}.rar`,
  `rar5-m3-{md128,big}.rar`, `rar5-flt-{e8,delta}.rar` and
  `rar5-s-{flt,link}.rar` and `rar{4,5}-s2.rar` (solid in groups of two)
  are committed.
  `Tools/fixtures/make-fixtures.sh` regenerates them with RARLAB's official
  `rar` for macOS. It downloads two pinned versions: 6.24 for RAR4 (RAR 7
  can no longer create RAR4) and 7.23 for RAR5. The Homebrew cask is disabled.
  The fixtures in `FixtureTests.supported` must match the oracle exactly;
  the others must fail with `.unsupportedCompression` until their phase lands.
- Name extraction in the tests uses `bsdtar`, because macOS `unzip` ignores
  the ZIP UTF-8 flag. `unzip -t` is used for integrity checks.

## Fuzzing

`Fuzz/` is a separate package with a libFuzzer harness
(`@_cdecl("LLVMFuzzerTestOneInput")`).

**It requires the swift.org toolchain**, because Xcode's toolchain rejects
`-sanitize=fuzzer`. Install it from <https://www.swift.org/install/> and select
it with `TOOLCHAINS`, then run:

```sh
Fuzz/build.sh        # build
Fuzz/build.sh run    # build and fuzz, seeded from Tests/Fixtures
```

`swift test` also includes a deterministic robustness suite: every truncation
and thousands of seeded mutations of valid archives.
