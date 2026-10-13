# Review hardening plan (issue #2)

Issue #2 reviewed commit 4712457 before the Grim Reader integration. This
plan covers its findings and acceptance criteria. Work happens in SwiftRAR
only; the Grim Reader side (its memory budget) is noted at the end.

Every new test is run against the unfixed code first and must fail there.

## 1. Names checked while parsing (High)

Today `RAR5Parser.parseFileHeader` and `RAR4Parser.parseFileHeader` read and
decode the full name of every entry and keep it; `planExtraction` checks
`maxNameLength` only afterwards. RAR4 allows 65,535-byte names, so 10,000
entries can hold about 650 MB of names before anything is rejected.

- Both parsers get `limits` down to `parseFileHeader` and throw
  `.limitExceeded(.nameLength)` as soon as the name length field exceeds
  `maxNameLength`, before reading the bytes. Service headers are checked
  too (their names are short: `CMT`, `RR`, `STM`, `QO`).
- `planExtraction` keeps its check (it limits the sanitised name).

Tests: one RAR4 and one RAR5 archive with a name of `maxNameLength + 1`
bytes; `RARArchive(source:limits:)` must throw. Fails today because the
parser accepts it.

## 2. Bound on total metadata

A header-only archive can still make the parser walk and allocate a lot:
many service headers, or RAR5 file headers up to 2 MiB each (extra area).

- New `Limits.maxHeaderBytes` (default 16 MiB): the sum of all header
  sizes read by the parser, every block type included. Exceeding it throws
  `.limitExceeded(.headerBytes)` (new `Limits.Kind` case).
- `maxEntries` keeps counting file headers only; the byte bound covers the
  skipped headers as well.
- `Limits.init` gets the new parameter with a default, so existing callers
  keep compiling.

Tests: many service headers (RAR4 and RAR5) above a small
`maxHeaderBytes`; must throw. Fails today because nothing counts them.

## 3. Window no larger than the entry needs (Medium)

The 57-byte archive from the review requests a 256 MiB dictionary for
3 bytes of output, and `Unpack50` allocates it before reading a block.

- A stream can never refer further back than the bytes it has produced.
  The window therefore only needs `min(dictionary, bytes in the stream)`,
  rounded as each decoder requires (`Unpack29`: power of two;
  `Unpack50`: at least 256 KB).
- Non-solid entry: the stream is the entry, so its `unpackedSize`.
- Solid archive: the stream is all compressed entries together.
  `RARDecoder.Session` gets an optional `streamSize` hint; `convertToCBZ`
  passes the sum of the planned unpacked sizes. Without the hint the
  session keeps today's behaviour (dictionary size), so a solid entry
  never needs a larger window than the first one allocated.
- Output for valid archives is unchanged. Only corrupt data that points
  beyond what was produced can differ, and the CRC rejects it anyway.
- PPMd memory cannot be clamped like this (the model would differ). That
  stays bounded by `maxPPMdMemory`; Grim Reader picks a tighter value.

Tests: the review's 57-byte RAR5 archive and a RAR4 equivalent; assert the
allocated window size (internal accessor through `@testable`) is at most
256 KB. Fails today (256 MiB). All fixtures must still match the oracle.

## 4. ZIP passthrough bounded and documented (Medium)

`convertToCBZ` copies anything starting with `PK\x03\x04` unchanged, with
no limits.

- `copyZIP` throws `.limitExceeded(.totalSize)` when the source is larger
  than `maxTotalSize`, before writing anything.
- The doc comments of both `convertToCBZ` variants and the README state it
  plainly: ZIP input is copied, not validated. Structure, names, sizes and
  CRCs of a ZIP are the caller's responsibility (Grim Reader reads CBZ with
  its own reader, which applies its own checks).

Tests: the review's 4,100-byte input with `maxTotalSize = 1` must throw.
Succeeds today.

## 5. Cancellation

The API is synchronous. Grim Reader runs it in a `Task`, and Swift lets
synchronous code read `Task.isCancelled` of the task it runs in.

- The parsers check it per header, the decoders per written chunk (every
  64 KiB or so, not per symbol), the stored extractor and `copyZIP` per
  chunk. They throw a new `RARError.cancelled`.
- The URL `convertToCBZ` already deletes its `.partial` file on any error,
  cancellation included.
- No new parameter: outside a task `Task.isCancelled` is false, so
  behaviour is unchanged for other callers.

Tests: run a conversion of a large fixture in a cancelled task; it must
throw `.cancelled` and leave no output file. Fails today (it completes).

## 6. Double CRC (profile first)

The decoder and `CBZWriter` both compute CRC32 over every byte. Per the
review's own criterion, measure before changing anything:

- Release-build benchmark of `rar4-m3-big` and `rar5-m3-big` with and
  without the writer's CRC (a temporary hack, not committed).
- If the writer's CRC is a clear share, add
  `CBZWriter.endEntry(verifiedCRC:)` for the conversion path, which keeps
  the decoder's check. If not, record the numbers and leave it.

Results go into the Outcome section below.

## Out of scope here

- Benchmarks on an iPhone with real comics: device work for Maarten. These
  belong to the Grim Reader integration.
- Grim Reader's memory and concurrency budget: its own `Limits` value
  (suggestion: dictionary 64 MiB, PPMd 64 MiB, one import at a time). That
  is decided and verified in the Grim Reader repo, after this.

## Files

`RARCore`: `Limits`, `RARError`, `RAR4Parser`, `RAR5Parser`, `RARArchive`
(stored extractor). `RARDecode`: `RARDecoder`, `Unpack29`, `Unpack50`.
`SwiftRAR`: `Convert`. Possibly `CBZWriter` (step 6). Tests, README,
CLAUDE.md.

## Outcome

Done on 2026-10-13. 135 tests pass (13 new), all fixtures still match the
oracle. Every new test failed against the unfixed code first.

1. Names: both parsers throw `.limitExceeded(.nameLength)` before keeping a
   name, service headers included. RAR4's name field may also hold the
   encoded Unicode name, so the field gets four times the limit and the
   decoded name the limit itself.
2. `Limits.maxHeaderBytes` (16 MiB) counts every header the parsers read.
3. `RARDecoder.Session(archive:limits:)` bounds the window; `convertToCBZ`
   uses it. The review's tiny RAR5 entry with a 256 MiB dictionary now gets
   the 256 KB minimum. rar sizes RAR4 dictionaries to the data
   (`rar4-m3` says 256 KB), so the RAR4 test rewrites the fixture's headers
   to the 4 MiB maximum. `Session(limits:)` keeps the old behaviour.
4. ZIP passthrough throws above `maxTotalSize`; README and doc comments say
   that ZIP input is not validated.
5. `RARError.cancelled` from the parsers (per header), the decoder session
   and stored extractor (per output chunk) and the ZIP copy (per chunk).
   The decoder test cancels after the first chunk of a compressed and a
   stored entry and checks that it stops at the next one.
6. CRC32 runs at about 400 MB/s here, so the second pass in the writer was
   a clear share. Release build, median of five runs, output discarded:

   | Fixture | Before | After |
   |---|---:|---:|
   | `rar4-m3-big` | 16.9 ms (109 MB/s) | 12.0 ms (153 MB/s) |
   | `rar5-m3-big` | 17.4 ms (106 MB/s) | 12.5 ms (147 MB/s) |
   | `rar5-flt-delta` | 4.1 ms (78 MB/s) | 3.3 ms (98 MB/s) |
   | `rar5-m0` (stored) | 3.5 ms (195 MB/s) | 1.8 ms (384 MB/s) |

   `CBZWriter.beginEntry(verifiedCRC:)` takes the CRC the extractor
   verifies; the conversion's own CRC comparison (the backstop) is gone,
   so the extractors' checks are the only ones on that path. A faster
   CRC32 (slicing) would speed up every path further; not done here.

Still open, for the Grim Reader integration: its own `Limits` and
concurrency budget, and benchmarks with real comics on an iPhone.
