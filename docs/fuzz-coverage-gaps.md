# Fuzz coverage gaps

Measured 16-10-2026 by replaying `Fuzz/corpus` (2028 inputs, after a 6.5 h
run with ASan: 5.1 M executions, no findings) against a coverage build.

Source coverage of the package: **86.6 % lines, 82.6 % regions, 83.9 %
functions.** The decoders are well covered (Unpack29 96 %, Unpack50 93 %,
PPMd 98 %, RAR5 filters 100 %). The gaps below are what remains.

## How to measure

Run outside the Claude Code sandbox: SwiftPM's build service cannot write
its manifest inside it.

```sh
export TOOLCHAINS=$(plutil -extract CFBundleIdentifier raw \
    ~/Library/Developer/Toolchains/swift-latest.xctoolchain/Info.plist)
swift build -c debug --package-path Fuzz --scratch-path Fuzz/.build/cov \
    -Xswiftc -sanitize=fuzzer -Xswiftc -profile-generate \
    -Xswiftc -profile-coverage-mapping -Xswiftc -parse-as-library
bin=Fuzz/.build/cov/out/Products/Debug/SwiftRARFuzz
LLVM_PROFILE_FILE=$TMPDIR/run.profraw $bin Fuzz/corpus -runs=0 -max_len=65536 -timeout=60
xcrun llvm-profdata merge -sparse $TMPDIR/run.profraw -o $TMPDIR/run.profdata
xcrun llvm-cov report $bin -instr-profile=$TMPDIR/run.profdata \
    -ignore-filename-regex='(Fuzz/|\.build/)'
```

Replaying the corpus takes about eight minutes in debug (four before
`RARReader` joined the harness).

## Gaps, most important first

1. **Done (16-10-2026): window wrap-around.** Three seeds from
   `Tools/fixtures/make-fuzz-seeds.sh`, 700 KB of near-repeats each
   (9–12 KB packed): `seed-rar4-wrap` and `seed-rar5-wrap` (smallest
   dictionary) reach `Unpack29.swift` 671–672 and `Unpack50.swift`
   301–307 and 511–512. Both decoders allocate at least 256 KB, not the
   128 KB of the RAR5 header. The filter wrap (`Unpack50.swift` 480–482)
   is unreachable with real rar output: rar never lets a filter block
   cross a 256 KB boundary of the file, and every real window is a
   multiple of that. `seed-rar5-wrap-flt` is E8 data whose file header is
   patched to a RAR7 dictionary of 256 KB + 1/32 (RAR5-compatible), so the
   window is 264 KB and four filter blocks wrap. That seed also covers
   the RAR7 dictionary encoding of gap 6 (`RAR5Parser.swift` 180–184).
   All three extract identically with SwiftRAR and `rar p`.
2. **Done (16-10-2026): `RARReader` in the harness.** `fuzzReader` in
   `Fuzz/Sources/SwiftRARFuzz/FuzzTarget.swift` reads every entry in order
   (alternating `extract` and `data(for:)`), then the last one again, which
   in a solid archive restarts the stream and skips the entries before it.
   Replaying the same corpus: `Reader.swift` 0 % → 92.7 % of lines, package
   86.6 % → 88.7 %. Still unreached: the stored branch (lines 90, 122, same
   cause as the `Convert.swift` side finding below), `init(url:)` and the
   foreign-entry guard (119). Replay now takes about eight minutes.
3. **Done (16-10-2026): RarVM Itanium filter.** RAR 6.24 never emits
   Itanium, and the real VM program is not public: UnRAR only knows its
   length and CRC. `make-fuzz-seeds.sh` therefore writes
   `seed-rar4-flt-itanium` itself: a stand-in program with that length,
   CRC and XOR byte, and one LZ block of 32 KB literals (flat tables, no
   matches) whose bundles carry patchable templates with opcode 5. rar
   6.24 must extract exactly the output of the script's Python copy of
   the filter; with a wrong CRC it fails. SwiftRAR extracts it
   identically. Replaying `Fuzz/seeds`: `RarVMFilters.swift` 137–157 and
   both bit helpers go from 0 to 2.25 k patched slots, the file from
   84.3 % to 98.1 % of lines.
4. **Done (16-10-2026): PPMd under memory pressure.** 1 MB is the
   smallest model memory the format allows, and at that size neither
   `seed-rar4-mct-heap` nor the full 425 KB `rar4-mct-mem` fixture ever
   splits a glued block (the fixture restarts 56 times, but no glue run
   frees more than 128 units). `seed-rar4-mct-restart` packs 320 KB of
   random blocks over 48 symbols, each written four times, at order 5
   into 59 KB: a repeat costs almost no bits but still adds contexts, and
   the wide alphabet gives state arrays large enough to glue into blocks
   above 128 units. Decoded once it restarts once and splits 8 times; rar
   6.24, unrar and SwiftRAR extract it identically. Replaying `Fuzz/seeds`
   without and with it: `PPMdModel.swift` 811 goes from 0 to 2,
   `PPMdHeap.swift` 273–275 from 0 to 16; `PPMdModel.swift` 92.3 % →
   94.8 % of lines, `PPMdHeap.swift` 87.8 % → 91.6 %, package 83.4 % →
   84.3 % (seeds only).
5. **Done (16-10-2026): solid continuation and mid-stream flushes.**
   Replaying `Fuzz/seeds` without and with the three new seeds (line
   counts; `Unpack29.swift` 189 is a comment, the call is on 190):
   - PPMd solid, `Unpack29.swift` 190: 0 → 3. `seed-rar4-mct-solid`:
     60 KB of x86-like code, then 60 KB of text in one file, plus a text
     file, at `-mct` (not `-mct+`). rar packs the code with LZ and switches
     to PPMd for the text. rar 6.24 and unrar extract the seed;
     **SwiftRAR failed on the second entry with `corruptData("PPMd
     symbol")`** (issue #8). Cause: end of block "1" did not clear
     `tablesRead` (UnRAR: `TablesRead3=!NewTable`), so the second entry
     skipped its new PPMd header. Fixed on 16-10-2026; the line on 190 was
     only reachable through that bug and is gone. A solid entry after PPMd
     always starts with a PPMd header, as UnRAR shows.
   - RAR5 solid, `Unpack50.swift` 144–147: 0 → 8 (147: 4).
     `seed-rar5-solid-grow`: four solid text files at `-md128k`; the
     header of entry 3 is patched to a 1 MB dictionary, so the guard on
     146 throws (rar 7.23: "Not enough memory"); rar tests the archive
     before the patch.
   - Broken solid stream, `RARDecoder.swift` 130: stays 0, unreachable
     from the harness. Both callers stop using a session after an error:
     `convertToCBZ` stops, and `RARReader` drops the session and restarts
     at the restart point, where the failing entry fails again. The guard
     only protects direct users of `RARDecoder.Session`. Entry 4 of
     `seed-rar5-solid-grow` would reach it through a session that goes on.
   - Flushes, `Unpack29.swift` 214–217 and `Unpack50.swift` 188–189:
     already 4 and 8 before these seeds, from the wrap seeds of gap 1 (this
     list was measured before them). Still 0 are two regions: `: 0` on
     216 (a filter that blocks the write) and `return false` on 189 (more
     written than the entry). Both need a filter block that runs past the
     end of an entry in a solid stream, which rar does not write.
   - Too many filters, `Unpack50.swift` 426–428: 0 → 2.
     `seed-rar5-flt-overflow` is written by hand: one block with tables
     for only a literal and the filter symbol, 8200 filter records for
     4 bytes 200 bytes ahead, then 16 literals. At 8192 the write cannot
     run any of them, so all are dropped. rar 7.23 extracts exactly the
     16 zeros, and SwiftRAR's CRC check passes.

   Lines: `RARDecoder.swift` 77.3 % → 84.6 %, `Unpack29.swift` 87.3 % →
   87.8 %, `Unpack50.swift` 91.5 % → 93.4 %, package 84.3 % → 85.4 %
   (seeds only).
6. **RAR5 header branches.** Encryption flags (84, 206), Unix and
   Windows timestamps (154, 247–251).

## Side findings

- `RARCore/BitReader.swift` and `Huffman.decodeSymbol(from: inout
  BitReader)` show 0 %: they are the bit-by-bit reference for the tests,
  the decoders use `StreamBitReader`. Not a fuzz gap.
- In `convertToCBZ` the stored-entry branch (`Convert.swift` 89) is never
  reached, although `StoredExtractor` itself is covered through the
  harness's own loop. Cause not investigated.
- The ZIP pass-through (`copyZIP`) is never reached. Low risk: it only
  copies bytes.

## Next step

Fix issue #8 (PPMd solid continuation) with `seed-rar4-mct-solid` as
the regression case, then gap 6, then measure the full corpus again and
run the fuzzer on it.
