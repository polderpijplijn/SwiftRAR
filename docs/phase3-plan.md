# Phase 3 plan: RAR4 filters and solid archives

Agreed with Maarten on 2026-10-13. Ports the filter handling
from UnRAR's `unpack30.cpp` (`ReadVMCode`, `AddVMCode`, `UnpWriteBuf30`,
`InitFilters30`) and the standard filters from `rarvm.cpp`
(`Prepare`, `ReadData`, `ExecuteStandardFilter`) to safe Swift, and makes
the unpack29 state survive across the entries of a solid archive.

## Scope

In: RAR4 UnpVer 29 entries with RarVM filters (code 257 in the LZ stream),
and solid RAR4 archives (per-entry solid flag), with or without filters.

Out: PPMd blocks, including filters inside a PPMd block
(`ReadVMCodePPM`, phase 4); RAR5 (phase 5); a general RarVM. A filter whose
program is not one of the six standard ones is rejected with
`.unsupportedCompression`. UnRAR 7 does the same: it no longer runs
arbitrary VM code, so such a filter yields its input there as well. We
throw instead, because silently writing unfiltered data would only fail
later on the CRC.

## Steps

### unRAR licence (RARDecode)

1. **`RarVMFilters.swift`** (new): the standard filters.
   - `StandardFilter` enum: `e8`, `e8e9`, `itanium`, `delta`, `rgb`,
     `audio`. Recognised like `RarVM::Prepare`: the XOR checksum byte, then
     length plus CRC32 of the program against UnRAR's table.
   - `readData` (`RarVM::ReadData`): the variable-length integer encoding
     of filter parameters, over a byte-array bit reader that yields zeros
     past the end, as `BitInput` does.
   - `apply(filter, registers, memory)`: the six transforms on a
     `[UInt8]` VM memory of 0x40000 bytes (+4, as UnRAR allocates), with
     every index checked. The parameter checks from UnRAR (`DataSize`,
     `Channels`, `Width`, `PosR`) stay; when one fails, the result is the
     unchanged memory, as in UnRAR (`FilteredData = Mem`).
2. **`Unpack29.swift`**:
   - Code 257 reads the VM code (`ReadVMCode`) and registers the filter
     (`AddVMCode`): the filter list, `oldFilterLengths`, `lastFilter`, and
     the pending stack with block start/length, `nextWindow` and the seven
     init registers. Caps from UnRAR: at most 8192 filters and 8192
     pending entries, code size below 0x10000.
   - Output moves to UnRAR's model: a write pointer (`WrPtr`) and the
     decode pointer (`UnpPtr`). The flush (`UnpWriteBuf30`) writes up to
     the next pending filter block, filters that block once it is complete
     (copied out of the window; the window itself stays unfiltered because
     later matches refer to it), chains filters on the same block, and
     stops at a block that is not complete yet. Register 6 is the number
     of bytes written to this file so far (`WrittenFileSize`).
   - Output to the sink stays capped at exactly `unpackedSize`. The
     written-size counter keeps counting past it, as UnRAR does, because
     the E8 filters use it as the file offset.
3. **Solid state**. Unpack29 becomes a long-lived decoder state with a
   `start(entry:input:)` per entry, mirroring `UnpInitData(Solid)`:
   - Non-solid entry: everything resets (window pointers, old distances,
     tables, filters).
   - Solid entry: the window, its pointers, the old distances, last
     length, the old table and `TablesRead3`, and the filter list and
     `oldFilterLengths` carry over. Pending filters, the bit input and the
     written-size counter reset per entry (`InitFilters30(true)`).
   - The window size is taken from the first entry of the solid block,
     as UnRAR does; later entries cannot grow it.
   - An entry no longer stops at `unpackedSize`. Like UnRAR it reads on
     to the "new file" marker (`00` or `01` after code 256), because `01`
     means the next entry starts with new tables. It stops early if the
     produced data passes `unpackedSize` by more than one maximum match,
     so a malformed stream cannot make it decode without bound. An empty
     entry in a solid block is decoded too: it may still carry tables or
     the end marker.
   - "A distance before the start produces zeros" now counts from the
     start of the solid block, not from the start of the entry.
4. **`RARDecoder`**: a new `RARDecoder.Session` (class) that lives for one
   archive and owns the Unpack29 state. `canDecode` accepts solid entries.
   The static `decode` stays for single non-solid entries and uses a
   one-off session.

### MIT (SwiftRAR)

5. **`Convert.swift`**: one session per archive. In a solid archive every
   compressed entry is decoded in archive order, including entries the
   plan skips (links): those go to a discarding sink but still have their
   CRC checked, because a broken link entry corrupts everything after it.
   `planExtraction` additionally checks limits and methods for those
   skipped solid entries.

### Tests

6. **New fixtures**, generated with RAR 6.24 by forcing one filter each
   (`-mcd+`, `-mce+`, `-mci+`, `-mca+`, `-mcc+`) over data that suits it,
   plus `rar4-s-flt`: a solid archive with filters on and several files,
   so filter reuse across entries is exercised. Existing fixtures stay
   untouched. `rar4-m3-flt`, `rar4-s` and the new ones move into
   `FixtureTests.supported`. If `rar` refuses to produce a filter type
   (E8 versus E8E9, Itanium), that type is reported as not covered by a
   fixture rather than covered by a self-made test vector.
7. **Filter coverage counter**: an internal per-session count of the
   filter types applied, so that each fixture test asserts that its
   filter actually ran. Without that, a fixture that rar packed without
   the filter would test nothing.
8. **`FilterTests`**:
   - `readData` against hand-encoded values of every length class;
   - each filter with out-of-range parameters returns its input and never
     traps;
   - corrupted and truncated `rar4-m3-flt` and `rar4-s` data throw a
     `RARError`, never trap;
   - a solid archive with a link entry in the middle converts.

   As in phase 2, every new test runs against the stub or the unfixed
   code first, followed by a mutation run over the filter and solid paths.

### Afterwards

9. A 5-minute fuzz run with the `rar4-m3-flt` and `rar4-s` seeds added.
   Then update `CLAUDE.md` (next step becomes phase 4, PPMd), the README
   and the NOTICE, and add the outcome to this document.

## Known risks

- RAR 6.24 may pick E8 or E8E9 by itself; only one of the two may be
  reachable with a fixture.
- Solid archives in which one entry is PPMd and another LZ share state
  between the two decoders. That only works once phase 4 lands; until then
  such an archive throws `.unsupportedCompression`.
- Throughput: filtering copies each filtered block out of the window once.
  The phase 2 figure (120-160 MB/s) is measured again after this phase.

## Outcome

Done on 2026-10-13. 96 tests green.

- All new fixtures match the unrar oracle byte for byte: `rar4-m3-flt`,
  `rar4-s`, `rar4-s-flt`, `rar4-s-link` and `rar4-flt-{e8,audio,delta,rgb}`.
  `FilterTests.testFixturesRunTheirFilters` proves which filters each one
  runs: E8, delta, audio and RGB are covered by fixtures; `rar4-s-flt`
  reuses delta and audio filters across solid entries.
- **E8E9 and Itanium have no fixture.** RAR 6.24 never emits them (tried:
  forced `-mce+`, `.exe` names, a file with an IA-64 ELF header). E8E9 is
  tested relationally against E8 (the same input with 0xE9 opcodes must
  give the same addresses), Itanium with a bundle built by hand. The
  `rar4-flt-ia64` fixture was dropped because it ran no filter.
- **Deviation from step 5 (links):** UnRAR reads a RAR4 link target raw
  from the packed data (`ExtractUnixLink30`), so a link never takes part in
  the solid stream. Decoding skipped links into a discarding sink, as
  planned, would have been wrong. Links stay simply skipped; `rar4-s-link`
  (a stored link between two solid entries) guards this.
- **Deviation from step 3 (end of entry):** running out of input ends an
  entry, as in UnRAR (no error by itself); the check that the output is
  complete then decides. This keeps non-solid entries without an
  end-of-file marker working while the decoder reads on to the marker.
- Mutation run, 22 mutations over the filters and the solid path. Caught:
  E8 (both address branches), E8E9 opcode, delta, RGB (green, Paeth),
  audio (coefficients, period), Itanium offset, `readData` negative class,
  register 6 (file offset), block start +258, old filter length, the
  blocked-filter `nextWindow` reset, solid tables, the end marker's
  new-table bit, solid window position and solid filter definitions.
  **Not caught**, because rar never produces the case in any fixture:
  chained filters on one block, `nextWindow` set at registration, reuse
  of the last filter without an index (`firstByte & 0x80 == 0`), and old
  distances carrying over between solid entries (a dedicated fixture with
  repeated blocks did not make rar use a repeat distance at an entry
  start, so it was dropped). These paths follow UnRAR line by line and are
  reached by the fuzzer for crash safety only.
- Performance (release, Mac mini, conversion into memory): unfiltered
  `rar4-m3` 124 MB/s and `rar4-m3-big` 112 MB/s, against 116 and 113 MB/s
  with the phase 2 code, so no regression. Filtered data is slower:
  `rar4-m3-flt` 115, `rar4-s-flt` 88, E8 69, audio and RGB 55 MB/s.
- Fuzzing: 705K runs in 5 minutes with the new fixtures as seeds,
  coverage 1362 (up from 970), no findings.
- Test time: the suite now takes about 35 s in debug, mostly the
  corruption test over filtered and solid fixtures (12 s) and the oracle
  comparison.
