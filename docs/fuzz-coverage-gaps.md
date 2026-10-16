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
3. **RarVM Itanium filter never runs** (`RarVMFilters.swift` 137–157 plus
   `itaniumBits` / `setItaniumBits`). Already known (CLAUDE.md): RAR 6.24
   never emits Itanium, so the tests use a hand-built bundle. A seed must
   be hand-built the same way.
4. **PPMd under memory pressure.** `restartAfterOverflow`
   (`PPMdModel.swift` 811) and the heap split at `PPMdHeap.swift` 273–275
   never run: the model never fills up. Seed: PPMd with the smallest
   memory size and enough varied data.
5. **Solid continuation and mid-stream flushes.** PPMd solid
   (`Unpack29.swift` 189), RAR5 solid (`Unpack50.swift` 144–147), a solid
   stream broken by an earlier entry (`RARDecoder.swift` 130), the flush
   paths (`Unpack29.swift` 214–217, `Unpack50.swift` 188–189) and the
   too-many-filters drop (`Unpack50.swift` 426–428).
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

Seeds for gaps 3, 4 and 5 (via `Tools/fixtures/make-fuzz-seeds.sh`,
prefixed `seed-`), then measure again
and run the fuzzer on the new corpus. Plan first: this touches more than
two files.
