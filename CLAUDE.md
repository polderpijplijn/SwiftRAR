# SwiftRAR: project notes

Pure-Swift RAR reader + CBZ writer for Grim Reader (iOS 16+, macOS 13+).
Converts CBR (RAR4/RAR5) to CBZ (stored ZIP). No external dependencies, no
C/C++, no libarchive. Everything in this repo is written in English.

## Build & test

- `swift build`, `swift test` (about 3 s). Locally, SwiftPM needs to run
  outside the Claude sandbox, because the clang module cache in
  `/var/folders` is not writable from inside it.
- Oracle: `Tools/oracle/build-unrar.sh` builds the official unrar from
  RARLAB's source into `Tools/oracle/.build` (git-ignored). Bump
  `UNRAR_VERSION` and `UNRAR_SHA256` together. Tests find it there, or
  through `$SWIFTRAR_UNRAR`, or in Homebrew.
- Fixtures are committed. `Tools/fixtures/make-fixtures.sh` regenerates them
  with pinned official `rar` builds (6.24 for RAR4, because RAR 7 dropped
  `-ma4`; 7.23 for RAR5), downloaded into `Tools/fixtures/.build`. The
  Homebrew `rar` cask is disabled because it fails Gatekeeper. Inside the
  sandbox, pass `TMPDIR` set to the scratchpad.
  Naming is `<rar4|rar5>-<variant>.rar`. `FixtureTests.storedVariants` lists
  the variants that must convert. Add a variant there when its phase lands.
- Fuzzing: `Fuzz/build.sh [run]` needs the swift.org toolchain. Swift 6.4.1
  is installed per user in `~/Library/Developer/Toolchains` on the Mac mini.
  The script selects `swift-latest` itself; Xcode stays the default
  elsewhere. Run it outside the sandbox. Example:
  `Fuzz/build.sh run -max_total_time=300 -artifact_prefix=Fuzz/`. Any
  `crash-*` file is a bug: add it as a regression test.
  Baseline on 2026-10-13: 13.7M runs in 5 min, coverage 404, no findings.
- Extract ZIPs in tests with `Tools.extractZIP` (bsdtar), never with
  `unzip -d`: macOS unzip mangles UTF-8 names.
- **Run a new test against the unfixed code first.** If it does not fail
  there, it does not test the bug. The `StoredExtractor` CRC check was only
  covered by the umbrella's backstop until a mutation run showed it.

## Licence split (do not blur)

| Target    | Licence | Notes |
|-----------|---------|-------|
| RARCore   | MIT     | original code: headers, bit reader, Huffman, CRC32, store, names, limits |
| CBZWriter | MIT     | original code |
| SwiftRAR  | MIT     | umbrella, `convertToCBZ(from:to:limits:)` |
| RARDecode | unRAR   | Swift port of UnRAR decompression; `LICENSE-UNRAR` is the unmodified text |

- Code ported from UnRAR goes **only** into `Sources/RARDecode`, with the
  licence paragraph in the source comments (see `RARDecoder.swift`).
  Never put UnRAR-derived code in an MIT target.
- **Never** use UnRAR as a basis for compression or for creating archives
  (the licence forbids it). SwiftRAR is a reader only.
- **Never commit the UnRAR source.** Only the oracle script that downloads it.
- README, NOTICE and this file describe the split. Keep all three in sync.

## Hard safety rules

- **No `Unsafe*` pointers.** An exception needs Maarten's explicit approval,
  and must be isolated and tested. The only existing exception is the
  libFuzzer C entry point in `Fuzz/` (outside the package), which copies the
  input into an array straight away.
- **Never trap on input.** Validate every offset and length before use, use
  checked arithmetic (`checkedAdd`, `checkedMultiply`,
  `addingReportingOverflow`), and throw a `RARError`. No `!`, no unchecked
  subscripts on input-derived indices, no `fatalError`.
- Port algorithms to idiomatic, safe Swift. Do not translate C++ pointer
  logic literally.
- **Do not port unrar's path or file-name logic.** Use `NameSanitizer`:
  `\` becomes `/`; drop `.`, `..` and empty components and a leading drive
  letter; reject control characters; no absolute paths.
- `Limits` is a required parameter with safe defaults: max entries, entry
  size, total size, ratio, name length and dictionary size.
- Verify the CRC of every entry. On a mismatch, abort and delete the
  half-written output (the URL API writes to a `.partial` temp file).
- Stream through `ByteSource` (`FileSource`/`DataSource`). Never load the
  whole archive into memory. A single read is capped at `maxReadSize`.
- No ZIP64. Throw at 4 GiB or more, or at more than 65,534 entries.

## Layout

- `RARCore/ArchiveFormat`: magic bytes (ZIP, RAR4, RAR5; RAR 1.4 is rejected).
- `RARCore/RAR4Parser`, `RAR5Parser`: block walk, header CRC, flags; they
  return `RAREntry` values with `dataOffset`.
- `RARCore/RARArchive`: `RARArchive` plus `StoredExtractor`.
- `SwiftRAR/Convert`: `planExtraction` validates everything first, then streams.
- `RARDecode/RARDecoder`: `canDecode` and `decode`. The phase 1 stub always
  throws `.unsupportedCompression`.

## Known gaps (phase 1)

- RAR4 names with the Unicode flag use the part before `\0` (legacy
  OEM/ANSI name). Decoding RAR's compressed Unicode name (unrar `encname`)
  belongs in RARDecode. Non-UTF-8 legacy names fall back to Latin-1.
- RAR5 entries without CRC32 (BLAKE2sp only, `rar -htb`) are rejected with
  `.missingChecksum`.
- Stored entries in a solid archive are extracted; they do not depend on the
  window.

## Next step

Phase 2: port unpack29 (RAR4 LZSS/Huffman) from UnRAR (`unpack30.cpp`, with
shared parts of `unpack.cpp` and `unpackinline.cpp`; the source comes from
`Tools/oracle/.build/unrar`) into `Sources/RARDecode`, using
RARCore's `BitReader` and `HuffmanTable`. Make `RARDecoder.canDecode`
return true for RAR4 entries with UnpVer 29 that are non-solid and need
no filters. Then move `rar4-m3` into `FixtureTests.storedVariants` (rename
the set to "supported") and compare it against the oracle. Solid
archives and filters are phase 3.

## Roadmap

Each phase ports the matching part of UnRAR into RARDecode and is validated
against the oracle (fixtures plus differential checks).

1. **Done:** format detection, RAR4/RAR5 headers, store extraction,
   CBZWriter, oracle, tests.
2. RAR4 v29 LZSS/Huffman (unpack29).
3. RAR4 standard filters (E8, E8E9, delta, RGB, audio, Itanium) without a
   full RarVM, plus solid archives.
4. PPMd variant H.
5. RAR5 LZ + filters (unpack50).
6. RAR 2.x (unpack20), if CBRs in that format turn up.
7. Fuzzing in CI, with differential comparison against the oracle. The
   harness exists already (`Fuzz/`); this phase adds CI and differential checks.
