# Phase 5 plan: RAR5 LZ and filters (unpack50)

Agreed with Maarten on 2026-10-13. Ports UnRAR's
`unpack50.cpp` (`Unpack5`, `ReadBlockHeader`, `ReadTables`, `ReadFilter`,
`AddFilter`, `UnpWriteBuf`, `ApplyFilter`) and the RAR5 parts of
`unpackinline.cpp` (`SlotToLength`, `CopyString`, `InsertOldDist`) and
`unpack.cpp` (`Init`, `UnpInitData` for RAR5) to safe Swift.

## Scope

In: RAR5 entries with algorithm version 0 (RAR 5.0 compression) and 1
(RAR 7.0, `ExtraDist`), solid or not, with the four RAR5 filters (delta,
E8, E8E9, ARM). After this phase `rar5-m3`, `rar5-s` and `rar5-mct` (plain
LZ, RAR5 has no PPMd) move into `FixtureTests.supported`.

Out: `unpack50mt.cpp` (multithreaded decoding; the single-threaded path
produces the same output), `unpack50frag.cpp` (see below), RAR 2.x (phase
6), encrypted and multi-volume entries (unchanged: rejected).

## Findings that shape the plan

Probed with the pinned RAR 7.23 before writing this:

- **rar shrinks the dictionary to the data.** `-md5g` over 0.8 MB was
  stored as `-md=1m`. So the dictionary in a header is at most about the
  size of the solid block, rounded up.
- **Non-power-of-two dictionaries and algorithm version 1 only exist above
  4 GB.** `-md3m` and `-md384k` are rejected ("Unknown option"). RAR 7 only
  writes the fraction bits and algorithm 1 (`VER_PACK7`) for dictionaries
  above 4 GB, which by the point above needs more than 4 GB of data. That
  is beyond our ZIP output (no ZIP64) and beyond `Limits.default`, so no
  real CBR reaches it, and no fixture can be made for it.
- `unpack50frag.cpp` (the fragmented window) only exists for 32-bit builds
  that cannot allocate one block. We target 64-bit iOS and macOS only and
  allocate one `[UInt8]`; it is not ported.

## Design decisions

- **Separate `Unpack50` state.** RAR4 and RAR5 share nothing in their
  bitstream, so `RARDecode/Unpack50.swift` is a new struct next to
  `Unpack29`, not a mode inside it. `RARDecoder.Session` keeps one of each
  (an archive is either RAR4 or RAR5) and picks by `unpackVersion`.
- **`unpackVersion` becomes unambiguous (RARCore, MIT).** Today a RAR5
  entry reports the raw algorithm version (0 or 1), a RAR4 entry its
  UnpVer (29). `RAR5Parser` maps them like UnRAR does: 50 for algorithm 0
  and for algorithm 1 with the `FCI_RAR5_COMPAT` flag (0x100000, which our
  parser ignores today), 70 for algorithm 1 without it. `canDecode`
  accepts 29, 50 and 70. The doc comment on `RAREntry.unpackVersion` and
  the tests that check the raw value change with it. Grim Reader does not
  read the field.
- **Window of arbitrary size, no mask.** RAR5 allows dictionaries that
  are not a power of two, so `Unpack50` uses UnRAR's `WrapUp`/`WrapDown`
  (compare and subtract) instead of `& mask`. Window size is
  `max(dictionary, 0x40000)` as in `Unpack::Init`. A larger existing
  allocation is reused (UnRAR's `AllocWinSize`); a solid entry that asks
  for a larger window than its block has throws `.corruptData` (UnRAR
  throws `bad_alloc`).
- **~~Smaller window for a non-solid entry~~ (dropped during the work).**
  The idea was `max(0x40000, min(dictionary, unpackedSize))` per
  non-solid entry, to save memory. A second probe showed rar already
  writes a dictionary of about the data size rounded up to a power of two
  (300 KB gets `-md=512k`, 4.8 MB gets `-md=8m`), so it would save at most
  half. And the first entry of a solid archive carries no solid flag, so
  a capped window would have needed growth logic for the entries after
  it. The window follows UnRAR exactly; `Limits.maxDictionarySize` still
  guards the header value.
- **Blocks at bit precision.** A RAR5 stream is a sequence of blocks, each
  with a header (flags, checksum, 1 to 3 size bytes) and a bit count for
  its last byte. The decode loop ends a block once the bit position
  reaches `blockStart * 8 + (blockSize - 1) * 8 + blockBitSize`, exactly
  UnRAR's `InAddr`/`InBit` test, then reads the next header (and its
  tables if present) until the block flagged `LastBlockInFile` ends. A
  header with a wrong checksum or 4 size bytes throws `.corruptData`. A
  symbol may straddle a block end, as in UnRAR; the reader is not cut at
  block boundaries. The entry also stops once the output passes its
  unpacked size (UnRAR's `WrittenFileSize > DestUnpSize`), and on
  `.truncated` input as `Unpack29` does.
- **Tables.** Bit-length table of 20, then 306 + 64 (or 80 with
  `ExtraDist`) + 16 + 44 lengths through the existing `HuffmanTable`. A
  "repeat previous" code at position 0 throws (UnRAR returns false). A
  block without tables before any table was read (`TablesRead5`) throws.
  Like `Unpack29`, over-subscribed tables throw where UnRAR decodes
  garbage; rar never writes them.
- **Distances in 64 bits.** `DBits` reaches 30 (39 with `ExtraDist`), so
  the high part is read in two pieces of at most 32 bits. `Int` is 64-bit
  on every target. A distance beyond the produced data or the window
  copies zeros (UnRAR's `CopyString` with `FirstWinDone`), the same rule
  `Unpack29.copy` already follows. The length bonus (+1 above 0x100,
  0x2000 and 0x40000) and the four old distances are ported as is.
- **Filters.** `ReadFilter`: start and length (1 to 4 bytes each), type
  in 3 bits, delta channels in 5 bits. A length above `0x400000` becomes 0
  (UnRAR). More than 8192 queued filters flush and then clear the queue.
  `ApplyFilter` gets a new `RAR5Filters` enum with delta, E8, E8E9 and
  ARM over a `[UInt8]` block of up to 4 MB. The RAR4 `RarVM` filters work
  on the 256 KB VM memory with registers and stay untouched. A filter type
  above ARM (UnRAR writes nothing for it) throws `.corruptData`, since
  the CRC would fail anyway. The write path ports UnRAR's `UnpWriteBuf`
  for RAR5, including `NextWindow` and the stop in front of an incomplete
  filter block. Filters never cross entries (`InitFilters` per file).
- **Solid state** follows `UnpInitData(Solid)`: a solid entry keeps the
  window, position, old distances, last length and tables; filters, the
  block header and the input are reset per entry. The existing session
  rule (no solid entry after a failed one) covers RAR5 too.
- **Coverage counter**, as in phases 3 and 4: blocks, blocks with and
  without tables, last-block ends, each filter type, repeat-last (257) and
  old-distance codes (258 to 261), window wraps, matches with distance
  bonus, and zero-filled copies. Fixture tests assert what each fixture
  covers.

## Steps

### MIT (RARCore)

1. **`RAR5Parser`**: `unpackVersion` 50/70 with the compat flag, doc
   comment on `RAREntry`, adjusted parser tests.

### unRAR licence (RARDecode)

2. **`RAR5Filters.swift`** (new): delta, E8, E8E9, ARM.
3. **`Unpack50.swift`** (new): state, window, block headers, tables,
   decode loop, filter queue, write path, coverage.
4. **`RARDecoder`**: `canDecode` for 50 and 70, `Session` dispatch and a
   `rar5Coverage` property, doc comments.

### Tests

5. **Fixtures with RAR 7.23** (deterministic data from the script):
   - existing `rar5-m3`, `rar5-s`, `rar5-mct` into `supported`;
   - `rar5-m3-md128`: `-md128k` over the 1 MB text, so the 256 KB window
     wraps inside one entry;
   - `rar5-m3-big`: the 1.8 MB binary with filters off, for long
     distances and the length bonuses;
   - `rar5-flt-e8` (x86-like data, `-mce+`) and `rar5-flt-delta`
     (`-mcd+` over the audio and image data);
   - `rar5-s-flt`: solid, several files, filters chosen by rar, with
     table-less blocks across entries;
   - `rar5-s-link`: solid with a symlink between two files.
   If rar never emits E8E9 or ARM (ARM has been off by default since 2019),
   those get no fixture, as in phase 3; they are tested against a
   straightforward reference in `RAR5FilterTests`.
6. **`Unpack50Tests`** (new):
   - corrupted and truncated `rar5-*` data throw a `RARError`, never trap,
     and finish within a time bound;
   - block header with a bad checksum, with 4 size bytes, a table-less
     first block, a repeat code at table position 0: `.corruptData`;
   - a header dictionary above `maxDictionarySize` throws before
     allocating;
   - a hand-built RAR5 stream (a small test-only bit writer: one block,
     fixed tables, literals and a match) decoded as algorithm 50 and as 70,
     to cover the 80-code distance table that no fixture can reach;
   - `RAR5FilterTests`: each filter against hand-computed output,
     including block lengths below 4 and E8 addresses at the sign
     boundaries.
   Every new test runs against a stub or the unfixed code first. After
   that, a mutation run over the decode loop, block handling, the write
   path and the filters.

### Afterwards

7. Release-build throughput on the RAR5 fixtures against unrar, a 5-minute
   fuzz run with the `rar5-*` seeds added, then `CLAUDE.md` (next step
   becomes phase 6 or 7), README and NOTICE, and the outcome in this
   document.

## Known risks

- **Block boundaries.** An off-by-one in the bit-level block end silently
  shifts the stream. Multi-block fixtures (`rar5-m3-big`, `rar5-s-flt`)
  and the coverage counter are the defence.
- **Write path with filters.** The RAR5 `UnpWriteBuf` differs from the
  RAR4 one (no VM memory, blocks up to 4 MB, `NextWindow` reset). The
  filter fixtures and the window-wrap fixture cover it; the mutation run
  shows what they miss.
- **No real `ExtraDist` data.** Algorithm 70 is only tested with a
  hand-built stream; it is a table-size switch on otherwise shared code.

## Outcome

Done on 2026-10-13. 124 tests green (about 145 s in debug).

- All nine RAR5 fixtures match the unrar oracle byte for byte: the existing
  `rar5-m3`, `rar5-s` and `rar5-mct`, and the new `rar5-m3-md128`,
  `rar5-m3-big`, `rar5-flt-e8` (now with `-md128k`, so filtered blocks meet
  the window wrap), `rar5-flt-delta`, `rar5-s-flt` and `rar5-s-link`. All
  of them passed on the first run of the port.
  `Unpack50Tests.testFixturesTakeTheirPaths` proves what each covers:
  repeat-last and old-distance codes, the length bonus, long distances,
  window wraps (also under the E8 filter), 106 blocks with the delta
  filter across solid entries, and solid continuation past a symlink.
- **Not covered by a fixture:** E8E9 and ARM (RAR 7.23 never emits them,
  not even for an `.exe` with `-mce+`), blocks without tables (rar starts
  every block with new ones), and the RAR 7.0 algorithm (above 4 GB only).
  Those are covered by hand-built streams from `RAR5Stream`, a test-only
  bit writer with fixed flat tables: filters registered in the stream
  (ARM, E8E9 at an offset, delta with 3 channels), a table-less second
  block, the 80-code distance table, a 5 MB distance read in two parts,
  and the length-bonus boundaries.
- **`rar5-s` and `rar5-s-link` exceed the 1000:1 ratio limit.** In a solid
  RAR5 stream RAR 7 packs a near-copy of an earlier file into almost
  nothing (`ComicInfo.xml`, 223 KB in 188 bytes). The fixture test
  loosens the ratio for those two. Worth knowing for Grim Reader: a solid
  CBR with duplicate pages could trip `Limits.default` the same way.
- **Parser change:** `unpackVersion` is now 50 or 70 for RAR5 entries, and
  algorithm version 0 reads 4 dictionary bits (it read 5).
- Mutation run, 36 mutations, then three tests added for the misses:
  33 caught. Every length, distance, table, block-header and filter
  constant that was mutated, the old-distance rotation, repeat-last, the
  filter start, file offset and incomplete-block rule, the flush margin,
  all filter bounds and the compat flag. The three misses that led to
  new tests: the 0x40000 bonus boundary, the shift of the upper distance
  bits (the long-distance test had zeros there), and the zero rule (now
  tested with a non-solid entry after one that filled the window).
  **Not caught (5), equivalent for valid archives:** the block bit size
  one bit early (the last symbol of a block never ends one bit before its
  end), `nextWindow` (rar never points a filter past unwritten data), a
  128 KB minimum window (rar keeps distances within the dictionary), and
  the two filter-queue housekeeping steps (more than 8192 queued filters).
- Performance (release, Mac mini): 80-270 MB/s; 115 MB/s on `rar5-s-flt`
  (3.8 MB in 0.033 s, unrar about 0.01 s).
- Fuzzing: 110K runs in 5 minutes, coverage 2274 (up from 2126), no
  findings. Seeds are cut at `-max_len=65536`, so the RAR5 fixtures only
  seed their first blocks.
