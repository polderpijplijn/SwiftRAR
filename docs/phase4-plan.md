# Phase 4 plan: PPMd variant H (RAR4 `-mct`)

Agreed with Maarten on 2026-10-13. Ports UnRAR's PPMd
decoder (`model.cpp`, `suballoc.cpp`, `coder.cpp`) and the PPM paths of
`unpack30.cpp` (the `BLOCK_PPM` branch of `Unpack29`, the PPM branch of
`ReadTables30`, `ReadVMCodePPM`, `SafePPMDecodeChar`) to safe Swift.

## Scope

In: RAR4 UnpVer 29 entries whose stream contains PPMd blocks, solid or
not: PPMd-only entries, switches between PPMd and LZ inside one entry
(escape 0 back to LZ, the `0x8000` table header into PPMd), PPMd state
carried across solid entries, LZ matches and RLE inside PPMd (escapes 4
and 5), and filters registered from inside a PPMd block (escape 3).

Out: RAR5 (phase 5, which has no PPMd), RAR 2.x (phase 6), RAR's
compressed Unicode names (`encname`, still a known gap).

## Design decisions

- **No pointers, one byte heap.** The PPMd model is a pointer graph inside
  one allocation, and its semantics depend on comparing addresses: a
  successor at or below `pText` is a position in the text area, not a
  context (`CreateSuccessors` reads `*(byte*)UpBranch`). So the port keeps
  a single `[UInt8]` heap and uses `UInt32` offsets as references, like
  7-Zip's Ppmd7. Offset 0 is NULL; the heap starts at offset 12 so no
  object ever has offset 0. Every field access goes through a checked
  accessor that throws `RARError.corruptData` outside the heap. No
  `Unsafe*`.
- **12-byte units, UnRAR's arithmetic.** Contexts (`NumStats` u16,
  `SummFreq` u16 or `OneState`, `Stats` u32, `Suffix` u32), memory blocks
  (`Stamp`, `NU`, `next`, `prev`) and states (6 bytes: symbol, freq,
  successor) get the original PPMd layout, so `UNIT_SIZE ==
  FIXED_UNIT_SIZE == 12`. The suballocator still follows UnRAR's code
  (`Size1`, `RealSize1`, `FakeUnitsStart`, the reserve unit before
  `HeapEnd`), which UnRAR designed to behave exactly like the 12-byte
  original. Where the model reads a field across layouts (the `Stamp`
  check in `GlueFreeBlocks` reads the first two bytes of whatever follows
  a free block), the first two bytes are the same in both layouts.
- **UnRAR's safety checks stay, plus a few.** The `MinContext` and
  `Stats` range checks in `DecodeChar`, the `ps[MAX_O]` cap in
  `CreateSuccessors` (CVE-2017-17969), the `ps[256]` and `NumMasked`
  checks in `decodeSymbol2`. On top of those: every linear search for a
  symbol in a stats array stops at `NumStats` (UnRAR relies on the symbol
  being there), and every suffix walk stops after 64 + 1 steps.
- **Errors throw.** Where UnRAR gets `-1` from `DecodeChar`, resets the
  model (`CleanUp`), switches to LZ and ends the file (which then fails on
  CRC), we throw `.corruptData`. The session already refuses solid
  entries after a failed one, so the outcome is the same: this entry and
  the rest of its solid block fail.
- **Byte input for the range coder.** `StreamBitReader` (RARCore, MIT)
  gets `readByte()`, used only at a byte boundary, which yields 0 past
  the end like UnRAR's `GetChar` and counts how far it read past the end.
  As in `UnpReadBuf30`, an entry ends at the top of the decode loop once
  input was read past its end. A cap of 64 KiB past the end throws
  `.truncated`, so zero bytes can never keep a model busy without bound.
  The existing output cap (unpacked size plus one match) still applies.
- **State across entries mirrors UnRAR.** The model, its heap, the range
  coder (`low`, `code`, `range`), `PPMEscChar` and the block type live in
  the `Unpack29` state:
  - Non-solid entry: block type LZ, escape char 2, and the model is
    discarded. Deviation from UnRAR, which keeps the model of the previous
    file in its `Unpack` object: a non-solid entry must not depend on
    other entries, so a PPMd header without the reset flag in a non-solid
    entry throws `.corruptData`. rar never writes one.
  - Solid entry: everything carries over, including a PPMd block that is
    still open. UnRAR only rereads the table header when `TablesRead3` is
    false, and `DecodeInit` never sets it, so the next solid entry may
    continue straight in PPMd with the old coder state over its own input.
    That is ported as is and checked with a solid fixture.
  - A heap of the same size is reused, as `StartSubAllocator` does.
- **Memory limit.** The PPMd header asks for 1 to 256 MiB of model
  memory. `Limits` gets `maxPPMdMemory` (default 256 MiB, the format
  maximum) and `Limits.Kind.ppmdMemory`, checked in `DecodeInit` before
  allocating. The new initialiser parameter has a default value, so
  existing callers (Grim Reader) still compile. `rar -mct` with default
  settings asked for 15 MiB in `rar4-mct`.

## Steps

### MIT (RARCore)

1. **`StreamBitReader.readByte()`** and an `overread` counter, as above.
2. **`Limits.maxPPMdMemory`**, `Kind.ppmdMemory`, README.

### unRAR licence (RARDecode)

3. **`PPMdHeap.swift`** (new): the byte heap, checked accessors for
   contexts, states and memory blocks, and the suballocator
   (`InitSubAllocator`, `AllocContext`, `AllocUnits`, `AllocUnitsRare`,
   `ExpandUnits`, `ShrinkUnits`, `FreeUnits`, `SplitBlock`,
   `GlueFreeBlocks`).
4. **`PPMdModel.swift`** (new): `ModelPPM` and the range decoder
   (`DecodeInit`, `DecodeChar`, `decodeBinSymbol`, `decodeSymbol1/2`,
   `update1/2`, `rescale`, `makeEscFreq2`, `CreateSuccessors`,
   `UpdateModel` with `RESTART_MODEL`, SEE2 contexts, `BinSumm`). The
   model reads its bytes through a closure or a small protocol over the
   `StreamBitReader`, so it does not own the input.
5. **`Unpack29.swift`**:
   - `readTables` with header bit `0x80`: `DecodeInit` (reset flag, max
     order with the `> 16` rule, memory, optional escape char; max order 1
     throws, as UnRAR stops there).
   - The PPMd branch of the decode loop: literal bytes, escape 0 (back to
     LZ tables), 1 (the escape byte itself), 2 (end of file), 3
     (`ReadVMCodePPM` into the existing `addFilter`), 4 (LZ match:
     distance in 3 bytes + 2, length + 32), 5 (RLE: distance 1, length
     + 4). These go through the existing `copy`, window, flush and filter
     paths unchanged.
   - Solid and non-solid initialisation as described above.
6. **`RARDecoder`**: the doc comment drops "PPMd throws". `Session`
   exposes a coverage counter (next step).

### Tests

7. **Coverage counter**, as with the filters in phase 3: per session, how
   many PPMd blocks started (with and without reset), each escape code,
   model restarts, `GlueFreeBlocks` runs, `AllocUnitsRare` taking units
   from the text area, and `rescale`. Each fixture test asserts the paths
   its fixture is meant to cover, so a fixture that rar packed differently
   cannot pass while testing nothing.
8. **New fixtures** with RAR 6.24, over deterministic generated text (a
   seeded word generator in `make-fixtures.sh`, so they are reproducible)
   plus the existing book:
   - `rar4-mct-s`: solid, `-mct+`, several text files: PPMd across solid
     entries, including continuation without a new header.
   - `rar4-mct-mix`: solid, `-mct` (rar decides per block) over text and
     images: PPMd/LZ switches inside and across entries.
   - `rar4-mct-mem`: `-mc63:1t+` (maximum order, 1 MiB) over about 2 MB of
     text: model restarts, `GlueFreeBlocks`, the rare allocation path,
     deep `CreateSuccessors` chains.
   - `rar4-mct-flt`: `-mct+` with filter-friendly binary data, to try to
     get escape 3 (filter inside PPMd).
   If rar does not produce a path (likely candidates: escape 3, escape 4,
   continuation of an open PPMd block across solid entries), that path is
   reported as not covered by a fixture, as E8E9 and Itanium were in
   phase 3, and tested with a hand-built stream only where that is
   feasible. `rar4-mct` and the new fixtures that pass move into
   `FixtureTests.supported` and are compared with the oracle.
9. **`PPMdTests`** (new):
   - corrupted and truncated `rar4-mct*` data throw a `RARError`, never
     trap, and finish within a time bound;
   - a PPMd header asking for more than `maxPPMdMemory` throws
     `.limitExceeded(.ppmdMemory)` before allocating;
   - hand-built headers: max order 1, and a header without reset in a
     non-solid entry, throw `.corruptData`;
   - suballocator unit tests: allocation, free and glue keep the free
     lists consistent (sizes from `Indx2Units`, no overlapping blocks).
   Every new test runs against the stub or the unfixed code first. After
   that, a mutation run over the model, the suballocator and the escape
   handling.

### Afterwards

10. Release-build throughput for the PPMd fixtures (the byte heap with
    checked access will be slower than LZ; in a CBR PPMd only packs
    `ComicInfo.xml` and other text, so this is reported, not a target). A
    5-minute fuzz run with the `rar4-mct*` seeds. Then update `CLAUDE.md`
    (next step becomes phase 5, unpack50), README and NOTICE, and add the
    outcome to this document.

## Known risks

- **Bit-exactness.** A single wrong increment in the model only shows up
  as different output much later. The oracle comparison over large and
  memory-starved fixtures is the main defence; the coverage counter shows
  whether restarts and glue actually happened.
- **Uninitialised memory in UnRAR.** UnRAR does not zero its heap. If the
  model ever reads a byte it never wrote, UnRAR's result depends on
  `malloc`. We zero on allocation; a difference against the oracle that
  traces back to such a read is documented, not imitated.
- **Speed.** Checked byte access with `UInt16`/`UInt32` assembled from
  bytes costs time. If it is far too slow, the hot accessors move to a
  word-aligned representation in a follow-up, still without `Unsafe*`.

## Outcome

Done on 2026-10-13. 105 tests green (about 130 s in debug).

- All six PPMd fixtures match the unrar oracle byte for byte: `rar4-mct`
  (now supported) and the new `rar4-mct-s`, `rar4-mct-mix`, `rar4-mct-mem`,
  `rar4-mct-flt` and `rar4-mct-rep`. `PPMdTests.testFixturesTakeTheirPPMdPaths`
  proves what each covers: model continuation across solid entries
  (headers without reset), PPMd to LZ inside an entry (escape 0) with
  filters in the LZ part, the literal escape byte (1), end of file (2), LZ
  matches (4) and RLE (5) inside PPMd, and in `rar4-mct-mem` 41 model
  restarts, glueing and allocations from the text area at order 61.
- **Not covered by a fixture:** escape 3 (a filter registered inside a PPMd
  block; once rar picks a filter for a file it packs that file with LZ),
  and an entry continuing an open PPMd block without a new header (rar
  always writes one). Both follow UnRAR line by line; the fuzzer reaches
  them for crash safety only.
- **Bug found by a fixture:** UnRAR's `GET_SHORT16` is an unsigned 16-bit
  cast. Read as signed, the SEE mean went negative on binary data only;
  the text fixtures all passed. `rar4-mct-flt` (PPMd over random data)
  caught it.
- **Fixture changes on the way:** `rar4-mct-mem` first used generated text
  without long repeats, so contexts never got deep enough for the order
  setting to matter; it now mixes in repeated passages. `rar4-mct-rep`
  dropped a 200 KB zero file whose 1:7700 ratio tripped `Limits`. The
  script now removes the PPMd archives before `rar a`, which otherwise adds
  to an existing archive.
- Mutation run, 44 mutations. Caught 33: every SEE, BinSumm, rescale,
  CreateSuccessors, UpdateModel and DecodeChar constant or comparison that
  was mutated, the escape 4/5 lengths and distance, the order rule above
  16, the initial run length, the memory limit, the split block and the
  in-place expansion. **Not caught (11):** the escape count after a
  restart (equivalent: `restartModel` clears the mask itself); the
  non-solid escape character, the end-of-input rule and escape 3 (valid
  rar output never reaches them); and seven allocator layout details
  (`pText` step back, the `LoUnit` stamp, the text-area bound, `RealSize1`,
  the glue counter, shrink reuse, the 64K glue cap) that only shift when
  memory runs out. `testSuballocatorKeepsLiveBlocksIntact` checks the
  allocator's integrity, which those mutations keep.
- Performance (release, Mac mini): 25-50 MB/s on text, 5 MB/s on
  `rar4-mct-mem` and on random data, against 0.18 s for unrar on
  `rar4-mct-mem` (ours 0.41 s). A CBR only packs text with PPMd, so the
  word-aligned heap from the risks section is not needed.
- Fuzzing: 131K runs in 5 minutes, coverage 2126 (up from 1362), no
  findings. Throughput dropped because a mutated PPMd header can ask for up
  to 256 MiB, which is allocated and zeroed (fuzzer RSS 722 MB).
