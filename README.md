# SwiftRAR

A pure-Swift RAR reader and CBZ writer for iOS and macOS, built for Grim Reader.
It converts CBR comic archives (RAR4/RAR5) into CBZ (stored ZIP) entirely in
Swift: no C/C++, no libarchive, no external dependencies.

```swift
import SwiftRAR

let result = try convertToCBZ(from: cbrURL, to: cbzURL, limits: .default)
```

ZIP input is copied unchanged (up to `maxTotalSize`) and is **not
validated**: a successful conversion of a ZIP says nothing about it being a
valid archive, so the caller checks it when reading the CBZ. RAR input is
fully validated before anything is written; output goes to a temporary file
that replaces the destination only on success.

The call is synchronous. Run it inside a `Task`: cancelling that task stops
the work at the next header or output chunk with `RARError.cancelled`.
An optional `progress` closure receives the fraction processed (0 to 1),
once per written entry (once per copied chunk for ZIP), on the converting
thread.

## Status

Phase 5 of 7. See `CLAUDE.md` for the roadmap.

| Input                              | Status                            |
|------------------------------------|-----------------------------------|
| ZIP / CBZ                          | copied unchanged, not validated   |
| RAR4 / RAR5, stored entries (`-m0`)| converted, verified by CRC32      |
| RAR4 compressed (`-m1`...`-m5`), solid or not, with standard filters, including PPMd (`-mct`) | converted, verified by CRC32 |
| RAR5 compressed (RAR 5.0 and 7.0 algorithms), solid or not, with its four filters | converted, verified by CRC32 |
| RAR4 with non-standard RarVM programs | `RARError.unsupportedCompression` |
| RAR 2.x compression (UnpVer 20/26) | `RARError.unsupportedCompression` |
| Encrypted archives or entries      | `RARError.encrypted`              |
| Multi-volume archives              | `RARError.multiVolume`            |
| RAR 1.4, SFX                       | not supported                     |

## Products

| Product     | Contents                                                        | License |
|-------------|-----------------------------------------------------------------|---------|
| `SwiftRAR`  | `convertToCBZ(from:to:limits:progress:)`; re-exports RARCore + CBZWriter | MIT     |
| `RARCore`   | format detection, RAR4/RAR5 headers, CRC32, bit reader, Huffman, store extraction, name sanitising, `Limits` | MIT |
| `CBZWriter` | streaming stored-ZIP writer (UTF-8 names, DOS time, no ZIP64)   | MIT     |
| (RARDecode) | decompression (RAR4 LZ, standard filters, PPMd; RAR5 LZ and filters), a Swift port of UnRAR; internal target | unRAR license |

## License

SwiftRAR is split-licensed:

- **RARCore, CBZWriter, SwiftRAR** (and tests, tools, fuzz harness): MIT, see `LICENSE`.
- **RARDecode**: the unRAR license, see `Sources/RARDecode/LICENSE-UNRAR` (the
  unmodified licence from UnRAR 7.3.1). RARDecode ports RARLAB's UnRAR
  decompression code. That licence allows its use to *handle* RAR archives
  but forbids using it to build a RAR-compatible archiver or to re-create the
  RAR compression algorithm. SwiftRAR is a reader only and never creates RAR
  archives.

Details are in `NOTICE`. The UnRAR source is not in this repository.

## Safety

- No `Unsafe*` pointers in the package (the only exception is the libFuzzer
  entry point in `Fuzz/`, which is not part of the package).
- Malformed input never traps. Every offset and length is checked before use,
  and every failure is a `RARError`.
- A `Limits` value is required on every call: entry count, entry size, total
  size, compression ratio, name length, dictionary size, PPMd model memory and
  the size of all headers together. Names and header bytes are checked while
  parsing, before anything is kept.
- The LZ window is never larger than the data it can hold: an entry's size
  (non-solid) or all compressed entries together (solid), even when the
  header asks for a larger dictionary.
- Names are sanitised: `\` becomes `/`; `.`, `..`, empty components and drive
  letters are removed; control characters are rejected.
- The CRC32 of every entry is verified. On a mismatch the partial output is deleted.
- Streaming I/O through `ByteSource` (`FileSource`, `DataSource`); the archive
  is never loaded into memory as a whole.
- No ZIP64: more than 65,534 entries, or any size or offset of 4 GiB or more,
  is an error.

## Testing

```sh
swift test
```

- **Oracle**: `Tools/oracle/build-unrar.sh` prints the path of an official
  `unrar`. It uses `$SWIFTRAR_UNRAR` or one on `PATH`, or otherwise downloads
  and builds UnRAR from RARLAB's source into `Tools/oracle/.build`. The tests
  convert archives with SwiftRAR and compare the result byte for byte with
  `unrar x`. Tests that need the oracle are skipped when it is missing.
- **Fixtures**: `Tests/Fixtures/{rar4,rar5}-{m0,m3,s,mct}.rar` plus
  `rar4-m3-{md64,big,flt}.rar`, `rar4-flt-{e8,audio,delta,rgb}.rar` and
  `rar4-s-{flt,link}.rar`, `rar4-mct-{s,mix,mem,flt,rep}.rar`,
  `rar5-m3-{md128,big}.rar`, `rar5-flt-{e8,delta}.rar` and
  `rar5-s-{flt,link}.rar` are committed.
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
