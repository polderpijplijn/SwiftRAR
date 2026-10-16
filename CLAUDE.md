# SwiftRAR: project notes

Pure-Swift RAR reader + CBZ writer for Grim Reader (iOS 16+, macOS 13+).
Converts CBR (RAR4/RAR5) to CBZ (stored ZIP). No external dependencies, no
C/C++, no libarchive. Everything in this repo is written in English.

## Build & test

- `swift build`, `swift test` (about 145 s in debug since phase 5; the
  PPMd fixtures dominate, `rar4-mct-mem` alone takes 20 s in debug and 0.4 s
  in release). Locally, SwiftPM
  needs to run outside the Claude sandbox, because the clang module cache in
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
  Naming is `<rar4|rar5>-<variant>.rar`. `FixtureTests.supported` lists the
  fixture stems (not variants) that must convert and match the oracle. Add a
  fixture there when its phase lands. The script can only regenerate all
  fixtures; to add one, run just its part with a copy of the script, so the
  committed ones stay untouched. `rar` picks RarVM filters on its own for
  binary data; pass `-mcd- -mce- -mci- -mca- -mcc-` for a filter-free one,
  or `-mc<n>d+`/`-mce+`/`-mc<n>a+`/`-mcc+` to force one. RAR 6.24 never
  emits E8E9 or Itanium, so those two are tested relationally (against E8)
  and with a hand-built bundle. `FilterTests.testFixturesRunTheirFilters`
  asserts which filters each fixture actually runs. `rar a` adds to an
  existing archive, so a rar call outside `make()` needs an `rm -f` first.
  The PPMd fixtures (`rar4-mct-*`) are described in the script's phase 4
  section; `PPMdTests.testFixturesTakeTheirPPMdPaths` asserts which PPMd
  paths (escapes, restarts, glue) each one takes. RAR 6.24 never emits
  escape 3 (a filter inside PPMd) and always starts a solid entry with a
  new PPMd header. Keep fixture entries under the 1000:1 ratio limit.
  Exception: in solid RAR5 fixtures RAR 7 packs near-copies of an earlier
  file far below that (`rar5-s`, `rar5-s-link`, `rar5-s2`);
  `FixtureTests.limitOverrides` loosens the ratio for exactly those. The RAR5 fixtures (phase 5 section of
  the script) are made with RAR 7.23, which never emits E8E9 or ARM, starts
  every block with new tables, and writes a dictionary of about the data
  size rounded up to a power of two (non-power-of-two sizes and the RAR 7.0
  algorithm only exist above 4 GB). `Unpack50Tests.testFixturesTakeTheirPaths`
  asserts what each covers; rare paths use the test-only `RAR5Stream`
  writer (fixed flat tables, no match finding).
- Fuzzing: `Fuzz/build.sh [run]` needs the swift.org toolchain. Install one
  per user in `~/Library/Developer/Toolchains` (tested with 6.4.1).
  The script selects `swift-latest` itself; Xcode stays the default
  elsewhere. Run it outside the sandbox. Example:
  `Fuzz/build.sh run -max_total_time=300 -artifact_prefix=Fuzz/`. Any
  `crash-*` file is a bug: add it as a regression test. Fuzz after every
  decoder change and before a new copy goes into Grim Reader; there is no
  scheduled fuzzing in CI.
  Baseline on 2026-10-13: 13.7M runs in 5 min, coverage 404, no findings.
  After phase 2: 730K runs in 5 min (decoding is real work now), coverage
  970, no findings.
  After phase 3: 705K runs in 5 min, coverage 1362, no findings.
  After phase 4: 131K runs in 5 min (PPMd is slow and a header may ask for
  256 MiB), coverage 2126, no findings.
  After phase 5: 110K runs in 5 min, coverage 2274, no findings (seeds
  are cut at 64 KB, so the RAR5 fixtures only seed their first blocks).
  After the review hardening (issue #2): 108K runs in 5 min, coverage
  2300, no findings.
  Overnight 2026-10-16: 5.77M runs in about 5 h, coverage 2497, no
  findings. A coverage report showed the filter fixtures never got past
  the 64 KB cut: RAR5Filters 0%, RarVMFilters 19%, PPMdHeap 58% of lines.
  `Fuzz/seeds` (from `Tools/fixtures/make-fuzz-seeds.sh`) holds small
  filter and PPMd-heap archives under 64 KB; alone they reach 75%, 84% and
  88%. rar never emits RAR5 ARM or RAR4 Itanium; ARM stays unreached,
  Itanium has the hand-written `seed-rar4-flt-itanium` (a stand-in
  program with the right length and CRC, checked against rar 6.24).
  Second overnight 2026-10-16 with those seeds: 5.1M
  runs in 6.5 h, no findings, 86.6% of package lines; the remaining gaps
  (window wrap-around, `RARReader` not in the harness, PPMd restarts) and
  the next step are in `docs/fuzz-coverage-gaps.md`. Measure coverage with a separate build:
  `-profile-generate -profile-coverage-mapping` instead of `address`,
  `--scratch-path` elsewhere, replay the corpus with `-runs=0`, then
  `llvm-profdata merge` and `llvm-cov report`.
- CI runs on GitHub-hosted runners only (#6), free for a public repo.
  Never put a self-hosted runner back while `pull_request:` is on: a fork
  PR would run its own code on that machine. Legs: `oldest` = `macos-26`
  with `Xcode_26.0.1` (Swift 6.2, the promised `swift-tools-version:6.2`)
  and `next` = the `xcode-27` preview image (`continue-on-error`).
  `ios-build` uses the image's default Xcode, the only one with the iOS
  platform installed. When the image drops a pinned Xcode,
  move to the oldest 26.x it still has. Tests run in release
  (`swift test -c release -Xswiftc -enable-testing`). The oracle binary
  is kept with `actions/cache`, keyed on the hash of `build-unrar.sh`.
- Every CI leg sets `SWIFTRAR_REQUIRE_ORACLE=1`, which turns every
  skip for a missing tool or fixture (`Tools.unavailable`) into a failure.
  Set it locally to check that nothing was skipped.
- Swift 6 language mode (tools 6.2): data races are compile errors, so there
  is no separate strict-concurrency step any more.
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

The `SwiftRAR` *product* links RARDecode, so it carries both licenses;
never describe it as just MIT. `RARCore` and `CBZWriter` alone are MIT.

- Code ported from UnRAR goes **only** into `Sources/RARDecode`, with the
  licence paragraph in the source comments (see `RARDecoder.swift`).
  Never put UnRAR-derived code in an MIT target.
- **Never** use UnRAR as a basis for compression or for creating archives
  (the licence forbids it). SwiftRAR is a reader only.
- **Never commit the UnRAR source.** Only the oracle script that downloads it.
- README, NOTICE, `Package.swift` and this file describe the split. Keep
  them in sync.

## Hard safety rules

- **No `Unsafe*` pointers.** An exception needs the maintainer's explicit approval,
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
  size, total size, ratio, name length, dictionary size, PPMd memory and
  header bytes. The parsers enforce name length and header bytes while
  walking the headers (service headers included), before keeping anything.
- Cancellation: synchronous code checks `Task.isCancelled` per header, per
  output chunk and per copied chunk, and throws `RARError.cancelled`.
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
  `RARReader` uses the same `planExtraction`, so both accept the same
  archives; only the CBZ entry limit stays in the conversion.
- `SwiftRAR/Reader`: `RARReader`, single-entry extraction without a ZIP.
  A compressed entry without the solid flag is a restart point; the reader
  keeps one session plus a cursor and decodes skipped entries into a
  discarding sink. Any error drops the session. `decodedEntries` (internal)
  lets tests count decodes. `ReaderTests.slow` leaves the big PPMd
  fixtures out of the every-order oracle test (backwards is quadratic).
  `Examples/ListAndExtract` is an outside package that CI builds and
  compares against unrar.
- `RARCore/ErrorCategory`: `category` on `RARError` and `CBZWriterError`.
  The switches are exhaustive on purpose; a new case must get a category,
  a row in `ErrorCategoryTests` and a row in the DocC error guide.
- `Sources/SwiftRAR/SwiftRAR.docc`: landing page, GettingStarted,
  Concurrency, Errors. CI runs `xcodebuild docbuild` and fails on any DocC
  warning; a missing symbol link is a warning, which a broken test link
  showed. The README duplicates the support table, limits, concurrency and
  error categories: keep both in step.
- `Examples/SwiftUIConvert`: `ConvertUI` (model + view, builds for iOS and
  macOS) plus a macOS app target. It shows the detached task, forwarded
  cancellation and main-actor progress. CI only compiles it; whether the
  UI stays responsive is a manual check.
- Releases: SemVer tags with three parts (`0.1.0`), because SwiftPM needs
  them; the apps' two-decimal convention does not apply. `CHANGELOG.md`
  is updated before tagging and names the UnRAR version RARDecode follows.
- `RARCore/StreamBitReader`: chunked bit input over a `ByteSource` range.
  `HuffmanTable.decodeSymbol(from: inout StreamBitReader)` is the
  table-driven hot path; the `BitReader` variant is the bit-by-bit reference.
- `RARDecode/RARDecoder`: `canDecode` (RAR4 UnpVer 29, RAR5 50 and 70;
  `RAR5Parser` maps algorithm 0, and 1 with the compat flag, to 50 and
  plain 1 to 70, as UnRAR does), `Session` (one per
  archive; solid entries continue from the previous one; after a failed
  entry it refuses further solid entries) and `decode` (CRC check).
  `Session(archive:limits:)` bounds the window by the data it can hold
  (entry size, or all compressed entries of a solid archive);
  `Session(limits:)` keeps the header's dictionary size.
- `CBZWriter.beginEntry(verifiedCRC:)`: the conversion hands over the CRC
  the extractor verifies, instead of a second CRC pass (that pass was a
  quarter to half of the conversion time). The extractors' own CRC checks
  are therefore the only ones on that path.
- `RARDecode/Unpack29`: the unpack29 port, including filter registration
  (`AddVMCode`) and the filtered write path (`UnpWriteBuf30`), plus the
  PPMd escapes (`ReadVMCodePPM`, LZ and RLE inside PPMd).
- `RARDecode/PPMdModel`, `PPMdHeap`: PPMd variant H on one `[UInt8]` heap
  with `UInt32` offsets (offset 0 is NULL; bytes 0..<12 are the glue
  sentinel) in the original 12-byte unit layout, so UnRAR's address
  comparisons (`<= pText`) carry over. Every access is checked. A
  non-solid entry discards the model (UnRAR keeps it). UnRAR's
  `GET_SHORT16` is an unsigned cast: reading it as signed broke the SEE
  mean on binary data only, which `rar4-mct-flt` caught.
  `StreamBitReader.readByte` yields zeros past the end (capped at 64 KiB);
  a PPMd entry ends once it read past its end, as in `UnpReadBuf30`.
- `RARDecode/Unpack50`: the unpack50 port (RAR5). Window of any size
  (`max(dictionary, 256 KB)`, compare-and-subtract instead of a mask),
  block ends at bit precision, `UnpWriteBuf` with `NextWindow`, distances
  in 64 bits (two reads above 16 high bits). A distance beyond the data
  of the solid block produces zeros, so a reused window never leaks the
  previous entry. An unknown filter type throws `.corruptData`; filtered
  blocks are capped at the entry size (UnRAR writes them whole).
  `unpack50frag.cpp` (32-bit fragmented window) and `unpack50mt.cpp` are
  not ported. `RAR5Filters`: delta, E8, E8E9, ARM on plain arrays.
- `RARDecode/RarVMFilters`: the six standard filters, recognised by
  program CRC like UnRAR. A non-standard program throws
  `.unsupportedCompression`; there is no general RarVM.
- Links: RAR4 stores a link target raw (UnRAR reads it straight from the
  packed data), so links never take part in the solid stream and are
  simply skipped.
- Performance: CRC32 runs at about 400 MB/s (table-driven, byte at a
  time); a faster CRC would help every path. Release build decodes about 120-160 MB/s on an Apple silicon Mac
  for RAR4 LZ, 80-270 MB/s for RAR5 (filtered data is the slow end; unrar
  is about 3x faster there); PPMd 25-50 MB/s on text, 5 MB/s when
  memory-starved or on random data (about 2x slower than the C unrar).
  Keep hot paths on concrete types across modules: the generic
  `CRC32.update<C: Collection>` was about 20x slower than the `[UInt8]`
  overload and was the bottleneck.

## Known gaps

- RAR4 names with the Unicode flag use the part before `\0` (legacy
  OEM/ANSI name). Decoding RAR's compressed Unicode name (unrar `encname`)
  belongs in RARDecode. Non-UTF-8 legacy names fall back to Latin-1.
- RAR5 entries without CRC32 (BLAKE2sp only, `rar -htb`) are rejected with
  `.missingChecksum`.
- Stored entries in a solid archive are extracted; they do not depend on the
  window.

## Next step

Issue #3 P1 is done (phases 8 and 9; `docs/phase9-plan.md`). What is left
in #3 is P2: RAR4 Unicode names and BLAKE2sp verification with real
fixtures, and a reproducible benchmark tool. The remote part of #1 (async
source for WebDAV range requests) stays open. Grim Reader can convert
every RAR4/RAR5 CBR that rar 3.x and later writes; worth a test on real
comics on the device first.

## Roadmap

Each phase ports the matching part of UnRAR into RARDecode and is validated
against the oracle (fixtures plus differential checks).

1. **Done:** format detection, RAR4/RAR5 headers, store extraction,
   CBZWriter, oracle, tests.
2. **Done (2026-10-13):** RAR4 v29 LZSS/Huffman (unpack29).
3. **Done (2026-10-13):** RAR4 standard filters (E8, E8E9, delta, RGB,
   audio, Itanium) without a full RarVM, plus solid archives.
4. **Done (2026-10-13):** PPMd variant H.
5. **Done (2026-10-13):** RAR5 LZ + filters (unpack50).
6. RAR 2.x (unpack20), if CBRs in that format turn up.
7. **Done (2026-10-13):** trustworthy CI (#3 P0): matrix, iOS build, strict
   concurrency, required oracle; a one-off differential check. No scheduled
   fuzzing in CI (decided); the harness in `Fuzz/` runs locally.
8. **Done (2026-10-13):** `RARReader` (#3 P1, #1 locally): list and
   extract single entries, random access in non-solid archives, restart
   points in solid ones.
9. **Done (2026-10-14):** integration docs (#3 P1): README as entry point,
   DocC, SwiftUI example, error guide with `ErrorCategory`, licensing per
   product, CHANGELOG/CONTRIBUTING/SECURITY, tag `0.1.0`.
