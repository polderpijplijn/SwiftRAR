# Phase 2 plan: unpack29 (RAR4 LZ/Huffman)

Agreed with Maarten on 2026-10-13. Ports UnRAR's RAR 3.x decompressor
(`unpack30.cpp`, plus the shared parts of `unpack.cpp` and
`unpackinline.cpp`) to safe Swift.

## Scope

In: RAR4 entries with UnpVer 29 that are non-solid, unencrypted, and need
no filters and no PPMd.

Out (later phases): filters (code 257, RarVM) and solid archives (phase 3),
PPMd blocks (phase 4), RAR5 (phase 5). If the decoder meets one of these
mid-stream, it throws `.unsupportedCompression`.

## Steps

### MIT, original code (RARCore)

1. **`StreamBitReader`**: reads bits MSB-first from the range
   `[dataOffset, dataOffset + packedSize)` of a `ByteSource`, in 64 KiB
   chunks. A compressed entry is never loaded into memory as a whole.
   Peeking past the end yields zeros. Consuming past the end throws
   `.truncated`.
2. **`HuffmanTable` fast path**: decodes through a 9-bit lookup table plus
   per-length limits. The current decoder works bit by bit and throws per
   bit, which is too slow for a 50 MB CBR on an iPhone. The existing
   guarantees stay: an over-subscribed table is rejected, and a code that
   falls into a gap throws.

### unRAR licence (RARDecode)

3. **`Unpack29.swift`**: ports `Unpack29`, `ReadTables30`,
   `ReadEndOfBlock`, `CopyString` and `InsertOldDist`.
   - The window is a `[UInt8]` of max(dictionary, 256 KiB), indexed through
     a mask.
   - Output is flushed to the sink in chunks, and capped at exactly
     `unpackedSize`.
   - A distance that reaches before the start of the data produces zeros,
     as unrar does.
   - Every loop iteration either produces output or consumes input, so a
     malformed stream cannot loop forever.
4. **`RARDecoder`**: `canDecode` returns true for `unpackVersion == 29`, not
   solid, not encrypted. `decode` verifies the CRC32 itself.
5. **`RARError.corruptData(String)`**: a new case for errors in the
   compressed bit stream (as opposed to the headers).

### Tests

6. **`FixtureTests`**: the set becomes "supported" and uses full fixture
   stems, because `rar4-m3` is supported while `rar5-m3` is not yet. The
   supported set is compared against the unrar oracle.
7. **New fixture `rar4-m3-md64`** (`-ma4 -m3 -md64k`). The existing content
   (~700 KB) fits in the default 4 MB window, so wrap-around is never
   exercised. Only this one archive is generated, and the existing fixtures
   stay untouched.
8. **`Unpack29Tests`**:
   - fast Huffman path against the bit-by-bit path, with random length
     tables;
   - `StreamBitReader` across chunk boundaries against `BitReader`;
   - corrupted and truncated `rar4-m3` data must throw a `RARError`, never
     trap.

   Each new test runs against the stub or the unfixed code first, to prove
   it can fail.

### Afterwards

9. A 5-minute fuzz run with the rar4-m3 seed. Then update `CLAUDE.md`
   (next step becomes phase 3), the README and the NOTICE.

## Known risk

If `rar4-mct` was packed without a PPMd block, it will convert after this
phase. In that case it moves to the supported set, and this is reported.

## Outcome

Done on 2026-10-13. 85 tests green.

- `rar4-m3`, `rar4-m3-md64` and the new `rar4-m3-big` match the unrar
  oracle byte for byte. `rar4-mct` contains PPMd blocks and still throws
  `.unsupportedCompression`, so the known risk did not occur.
- Deviation from the plan: the md64 fixture alone did not reach every code
  path. A mutation run showed that the length bonus for distances of 256 KiB
  or more, and the low-distance repeat code, were untested. Two more fixtures
  were added from one 1.8 MB binary:
  - `rar4-m3-big` (filters off) now catches both mutations;
  - `rar4-m3-flt` (filters on, so rar emits RarVM code) is the first fixture
    for phase 3.
- Mutation checks: flushing past the window wrap, a slow-path Huffman skip,
  the low-distance repeat count, the long-distance bonus, the 0x2000
  threshold and the high distance bits. Every one of them fails the suite.
- Performance: the release build ran at 20 MB/s at first. Profiling showed
  that the generic `CRC32.update` was the bottleneck, because it is not
  specialised across modules. With a concrete `[UInt8]` overload, decoding
  runs at 120-160 MB/s. The stored path and CBZWriter benefit as well.
- Fuzzing: 730K runs in 5 minutes, coverage 970 (up from 404), no findings.

