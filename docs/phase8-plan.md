# Phase 8: supported extraction API (issue #3 P1, with #1)

Status: approved 2026-10-13 (strict open, name `RARReader`); done, see Outcome.

Issue #3 P1 has three parts: an extraction API, integration documentation,
and a capability/licensing table. This phase covers **only the extraction
API**. The documentation and licensing parts follow as a separate phase,
because they should describe the API that comes out of this one.

Issue #1 (read a single page without converting) is covered for local
sources. Its remote part (an async `ByteSource` for range requests during a
WebDAV scan) stays open in #1.

## Today

- `RARArchive` (RARCore) lists entries from the headers only, and
  `StoredExtractor` extracts stored entries. Both are public, but they leave
  every safety check to the caller.
- `RARDecoder.Session` (RARDecode) decodes compressed entries, but RARDecode
  is an internal target: not a product, so not usable from outside.
- The checks that make extraction safe (encrypted, multi-volume, method,
  dictionary, checksum, entry size, ratio, total size, name sanitising,
  duplicates) live in `planExtraction` in `Convert.swift`, private to the
  conversion.

## API

One new type in the `SwiftRAR` product, `Sources/SwiftRAR/Reader.swift`:

```swift
/// Lists the files of a RAR archive and extracts them one at a time,
/// without creating a ZIP.
public final class RARReader {
    public struct Entry: Equatable, Sendable {
        public let index: Int          // position in `entries`
        public let name: String        // sanitised, unique
        public let rawName: String     // as stored in the archive
        public let size: UInt64        // unpacked
        public let modified: Date?
        public let isCompressed: Bool
    }

    public let format: ArchiveFormat   // .rar4 or .rar5
    public let isSolid: Bool
    public let entries: [Entry]        // files only; no directories, no links

    public init(source: ByteSource, limits: Limits) throws
    public convenience init(url: URL, limits: Limits) throws

    /// Streams one entry to `sink` and verifies its CRC32.
    public func extract(_ entry: Entry, into sink: ([UInt8]) throws -> Void) throws

    /// The whole entry in memory, returned only after its CRC32 matched.
    public func data(for entry: Entry) throws -> Data
}
```

- **Validation at open, same rules as conversion.** `init` reads the
  headers and runs the checks from `planExtraction` over all files. Any
  problem (an encrypted or unsupported entry, a limit, a bad or duplicate
  name) fails the open, as it fails a conversion today. One rule set, so a
  CBR that converts also reads, and the other way round.
  `planExtraction` is split into the shared check (in `SwiftRAR`) and the
  CBZ-only part (`CBZWriter.maxEntries`), which stays in the conversion.
- **Bytes are provisional.** `extract` passes data to `sink` as it is
  decoded; the CRC32 is checked at the end. On any error the caller must
  discard what it received. `data(for:)` is the safe shortcut for small
  entries such as a comic page: it returns nothing until the check passed.
- **No filesystem extraction.** Writing entries to disk (destination,
  symlink and overwrite policy) is a separate decision, as the issue asks.
  The sanitised `name` is a key, not a safe path.

## Random access and solid archives

One rule covers both kinds of archive. A compressed entry whose solid flag
is clear starts a new decoder stream: a **restart point**. In a non-solid
archive every compressed entry is one; in a solid archive usually only the
first (more with RAR's `-s<N>` groups). Stored entries are never part of the
stream, so they are always read directly.

The reader keeps one `RARDecoder.Session` and a cursor: the next compressed
entry the session can continue with. `extract(k)`:

1. stored → `StoredExtractor`, cursor untouched;
2. compressed and `k` is the cursor, or `k` is a restart point → decode `k`
   (a restart point starts from a fresh session);
3. compressed and `k` lies after the cursor in the same stream → decode the
   entries from the cursor up to `k` into a discarding sink (their CRCs are
   still verified), then `k` into the caller's sink;
4. otherwise (`k` lies before the cursor) → fresh session at the restart
   point before `k`, then as 3.

So non-solid archives get true random access; reading a solid archive in
order costs one pass in total; reading a solid archive backwards costs a
pass per entry. That cost is documented on `RARReader`, so an app can
choose to convert solid archives instead, as Grim Reader does today.

**After an error** (CRC mismatch, corrupt data, cancellation) the session is
dropped and the cursor cleared. The next `extract` starts again at a restart
point, so a cancelled page load does not poison the reader.

**Concurrency.** `RARReader` is not `Sendable` and not thread-safe:
`FileSource` seeks a shared file handle and the session holds decoder state.
One reader per task; to read in parallel, open two readers. Cancellation of
the surrounding `Task` works as in conversion (`RARError.cancelled`).

## Products and licensing

`RARReader` lives in the `SwiftRAR` product, which already depends on the
unRAR-licensed RARDecode. RARDecode stays an internal target: no new product,
so the licensing picture does not change. The licensing table itself is
part of the documentation phase.

## Tests (`Tests/SwiftRARTests/ReaderTests.swift`)

Against the oracle (`unrar p` per entry), over the existing fixtures:

- every entry of every supported fixture, in archive order, matches;
- **non-solid random access:** entries in reverse and shuffled order
  match, and the session decodes only the requested entry (an internal
  counter of decoded entries, as `windowBytes` is today);
- **solid:** reverse and shuffled order match (`rar4-s`, `rar5-s`,
  `rar4-mct-s`, `rar4-s-flt`, `rar5-s-flt`); in-order reading decodes each
  entry exactly once;
- stored entries in a solid archive do not move the cursor;
- open fails on the same inputs as conversion: encrypted, unsupported
  method, each limit, duplicate names;
- **CRC failure:** a fixture with one corrupted data byte throws
  `.badDataCRC`; `data(for:)` returns nothing; the next `extract` of an
  undamaged entry in the same reader still succeeds;
- **cancellation:** a cancelled task throws `.cancelled`, and a later
  `extract` from a live task succeeds;
- the robustness suite (truncations, mutations) also runs through
  `RARReader` and only ever throws `RARError`.

Per the working rule, the order-dependent tests are first run against a
naive version (one session, no cursor) to confirm they fail there.

## External sample (`Examples/ListAndExtract/`)

A separate SwiftPM package with a path dependency on the repository: a
command-line tool that lists an archive and writes one entry to stdout. It
uses only the `SwiftRAR` product. CI builds it in the `test (current)` job
(`swift build --package-path Examples/ListAndExtract`, a few seconds), which
covers the issue's acceptance "an external SwiftPM sample lists and
extracts stored and compressed entries through supported products".

## Out of scope

- README rewrite, DocC, SwiftUI example, error guide, licensing/capability
  table, release tag: the documentation phase that follows.
- Remote/async reading (#1, remote part).
- Grim Reader showing CBR pages without converting: a change in that repo,
  after this lands and the vendored copy is updated.

## Files

- new `Sources/SwiftRAR/Reader.swift`
- `Sources/SwiftRAR/Convert.swift`: shared check split out of `planExtraction`
- `Sources/RARDecode/RARDecoder.swift`: internal decoded-entry counter for
  tests (no behaviour change)
- new `Tests/SwiftRARTests/ReaderTests.swift`, one corrupted fixture
- new `Examples/ListAndExtract/`
- `.github/workflows/ci.yml`: build the sample
- `README.md` (one short section), `CLAUDE.md` (next step, roadmap)

## Open questions for Maarten

1. **Strict open** (proposed): one unsupported or encrypted file makes the
   whole archive unreadable, as in conversion. Alternative: list
   everything and fail only when that entry is extracted. More lenient, but
   a second rule set, and in a solid archive a bad entry breaks every entry
   after it anyway.
2. **Name `RARReader`.** It reads RAR only; a ZIP throws `.unknownFormat`.

## Outcome (2026-10-13)

Built as planned, with these differences:

- **No change to `RARDecoder.swift`.** The decode counter lives in the
  reader (`decodedEntries`, internal), so RARDecode is untouched.
- **New fixtures `rar4-s2` and `rar5-s2`** (`-s2`, solid in groups of two),
  because no fixture had a restart point inside a solid stream. Generated
  with the pinned rar 6.24 and 7.23; added to `make-fixtures.sh` and to
  `FixtureTests.supported`. `rar5-s2` needs the looser ratio too
  (`ComicInfo.xml` packs to 188 bytes, 1185:1), so the sample in CI uses
  `rar4-s2`.
- **The corrupted fixture is made in the test** (one flipped byte in
  `page03.jpg` of `rar4-s2`), not committed.
- **Slow fixtures.** Reading every fixture in three orders took 255 s in a
  debug build, almost all of it in the large solid PPMd fixtures
  (`rar4-mct-flt` alone 135 s: backwards is one pass per entry).
  `rar4-mct-flt`, `-mix` and `-mem` are left out of that test
  (`FixtureTests` decodes them forwards with the same session code;
  `rar4-mct-s` keeps solid PPMd in every order). The test now takes about
  45 s.
- **CI** builds `Examples/ListAndExtract` in `test (current)`, lists
  `rar4-s2` and compares two extracted entries with `unrar p` using `cmp`.

Checked against a naive reader (one session, no cursor, no restart): the
every-order oracle test, both recovery tests (corruption, cancellation),
the restart-group test and the last-entry-first test fail there; the tests
for non-solid access, in-order reading, validation and robustness pass
there too, as expected.

Not checked: Grim Reader using the reader (separate change in that repo),
and the reader on real comics on a device.
