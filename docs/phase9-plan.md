# Phase 9: integration docs, capabilities and licensing (issue #3 P1)

Status: approved 2026-10-14 (add `RARError.category`, tag `0.1.0`, build
the SwiftUI example for iOS too); done, see Outcome.

Phase 8 delivered the extraction API (`RARReader`). This phase covers the
other two P1 parts of #3: "make the first integration straightforward" and
"make capabilities and licensing unambiguous". It is documentation, one
example and CI, plus at most one small API addition (see Open decisions).
No decoder code changes.

## Today

- `README.md` starts with one conversion call, still says "Phase 5 of 7",
  and points at `CLAUDE.md` for the roadmap.
- The support table misses the two known gaps from `CLAUDE.md`: RAR4
  compressed Unicode names fall back to the legacy name, and RAR5 entries
  with only BLAKE2sp are rejected with `.missingChecksum`.
- The products table calls the `SwiftRAR` product "MIT", even though it
  links the unRAR-licensed RARDecode.
- "Malformed input never traps" is stated as an absolute.
- No DocC, no SwiftUI example, no error guide, no CHANGELOG, no tag, no
  CONTRIBUTING or SECURITY file, and the repository has no description or topics.

## Deliverables

### 1. README rewritten as the entry point

Order: what it is, then installation, products and licenses, quick start
(conversion and reader), support table, limits and memory, concurrency,
errors (short, links to the guide), safety, testing, fuzzing.

- **Installation:** a complete `Package.swift` snippet with
  `.package(url: "https://github.com/polderpijplijn/SwiftRAR.git", from: "0.1.0")`
  and `.product(name: "SwiftRAR", package: "SwiftRAR")`. Platforms: iOS 16,
  macOS 13. Toolchains: Swift 5.9 (Xcode 15.2) through the current Xcode,
  as tested in CI.
- **Product selection with licenses** (replaces the products table):

  | Product     | You get                         | Licenses you take on   |
  |-------------|---------------------------------|------------------------|
  | `SwiftRAR`  | conversion, `RARReader`, all of RARCore and CBZWriter | MIT **and** unRAR (via RARDecode) |
  | `RARCore`   | headers, listing, stored entries only | MIT                  |
  | `CBZWriter` | stored-ZIP writer               | MIT                    |

  Plus one sentence on what the unRAR license forbids (building a RAR
  archiver), and that the paragraph in `NOTICE` must go into the app's
  acknowledgements. `NOTICE` and the `Package.swift` comment get the same
  wording.
- **Support table:** the current rows plus "RAR4 Unicode names: legacy
  name is used (may differ from what WinRAR shows)" and "RAR5 entries
  checked by BLAKE2sp only: `.missingChecksum`". ZIP passthrough stays
  marked as not validated.
- **Validation stages:** a short section that separates the *preflight*
  (headers, names, limits, flags: done before any output, at
  `RARReader.init` or the start of `convertToCBZ`) from the *payload*
  check (CRC32 per entry, known only when that entry's last byte is
  decoded). Robustness is described as "every offset and length is
  checked, and truncation/mutation/fuzz testing has found no traps",
  not "never traps".
- **Memory:** the worst case per open archive under `Limits.default`
  (LZ window up to `maxDictionarySize`, but never more than the data it
  can hold; PPMd model up to `maxPPMdMemory`; headers up to
  `maxHeaderBytes`; `data(for:)` holds one entry up to `maxEntrySize`).
  The limits apply per call, not per process: an app that imports N
  archives at the same time needs N times that budget, so it should
  import one at a time on iPhone or tighten the limits.
- `Status` with the phase count is removed; the roadmap stays in
  `CLAUDE.md` and is no longer linked as user documentation.

### 2. DocC catalog

`Sources/SwiftRAR/SwiftRAR.docc/` with:

- `SwiftRAR.md` (landing page and topic groups),
- `GettingStarted.md` (installation, the two quick starts, custom
  `ByteSource`, limits, cancellation and progress),
- `Concurrency.md` (the contract, see 4),
- `Errors.md` (the error guide, see 5).

The public symbols that lack doc comments get them (`convertToCBZ`,
`RARReader` and `Entry`, `Limits`, `ByteSource`, `FileSource`,
`DataSource`, `RARArchive`, `RARError`, `CBZWriterError`).

No `swift-docc-plugin` dependency: it would become a package dependency
for every consumer. CI builds the docs with
`xcodebuild docbuild -scheme SwiftRAR -destination 'generic/platform=macOS'`
and fails on DocC warnings (broken symbol links). The docs are not
published; Xcode shows them after the package is added.

### 3. SwiftUI example

`Examples/SwiftUIConvert`: a separate SwiftPM package with one executable
target (`@main struct App`), macOS 13 and iOS 16, that uses only the
`SwiftRAR` product. One view: pick a CBR (`fileImporter`), convert, a
`ProgressView`, a Cancel button.

What it has to show correctly:

- **Off the main actor:** the work runs in `Task.detached(priority:
  .userInitiated)`. A plain `Task {}` started from a view inherits the
  main actor, and from Swift 6.2 a `nonisolated async` function runs on the
  caller's actor as well, so neither moves the synchronous conversion off
  the UI thread.
- **Cancellation:** the view model keeps the detached task's handle. Cancel
  calls `handle.cancel()`. `convertToCBZ` checks `Task.isCancelled` and
  throws `.cancelled`, and the view treats that as "stopped", not as an
  error.
- **Progress on the main actor:** the `progress` closure runs on the
  converting thread. It forwards to the main actor with
  `Task { @MainActor in model.fraction = f }`, throttled to whole
  percentages so the UI is not flooded.
- Security-scoped access for the picked URL is started and stopped
  around the conversion (iOS needs it, macOS sandboxed apps too).

CI: `swift build --package-path Examples/SwiftUIConvert` on the `current`
job (macOS), and an `xcodebuild build -destination 'generic/platform=iOS'`
of it in `ios-build`. Both only compile. No simulator, no UI test.
Whether the UI really stays responsive is checked by hand (Maarten, on a
Mac or device), and the outcome section will say so.

### 4. Concurrency contract (DocC article + README section)

- `convertToCBZ` is a free synchronous function. Concurrent calls on
  *different* files are safe: they share no state. Memory adds up (see 1).
- `RARReader`, `RARArchive`, `FileSource`, `DataSource` and `CBZWriter` are
  **not** thread-safe and not `Sendable`: `FileSource` seeks one file handle
  and the reader keeps a decoder session and cursor. Use one per task, or
  give one task ownership. Do not share an instance between tasks.
- `Limits`, `RARReader.Entry`, `RARError` and `CBZWriterError` are
  `Sendable` values.
- Cancellation is cooperative: it is checked per header and per output
  chunk, and `RARError.cancelled` is thrown.
- `progress` and the `extract` sink are called synchronously on the
  calling thread.

This documents how the code already behaves; no code changes. The
non-Sendable types get a one-line doc comment saying so, so that adding
`@unchecked Sendable` later is visibly a contract change. The compiler
already rejects passing them across tasks under strict concurrency.

### 5. Error guide (`Errors.md`, short version in README)

A table of every `RARError` and `CBZWriterError` case in four groups,
each with what the app should do:

| Group        | Cases | App should |
|--------------|-------|------------|
| Corrupt or not an archive | `unknownFormat`, `truncated`, `corruptHeader`, `corruptData`, `badHeaderCRC`, `badDataCRC`, `missingChecksum`*, `emptyArchive`, `invalidEntryName`, `duplicateEntryName` | report "damaged file", do not retry |
| Unsupported feature | `unsupportedFormat`, `unsupportedCompression`, `encrypted`, `multiVolume` | report "not supported", suggest converting elsewhere |
| Policy limit | `limitExceeded(kind)` | report "too large", or retry with looser `Limits` if the app chooses |
| Environment | `io`, `cancelled`; writer `io`, `zip64Required`, `tooManyEntries`, `invalidState` | I/O: report, maybe retry; cancelled: silent |

\* `missingChecksum` is "unsupported" for BLAKE2sp-only RAR5 entries.
The guide says so explicitly.

### 6. Release, changelog, versioning

- `CHANGELOG.md` (Keep a Changelog style) with one entry, `0.1.0`,
  summarising phases 1–9.
- Versioning policy in the README: SemVer. SwiftPM requires three-part
  tags (`0.1.0`), so the two-decimal app convention does not apply here.
  While on 0.x, a minor bump may break the API. Each tag says which UnRAR
  version RARDecode follows (7.3.1).
- Tag `0.1.0` on the commit where CI is green, **only after Maarten's
  go-ahead**. No GitHub Release object unless he wants one.
- No changelog sync to the support repo (that is for apps).

### 7. Repository hygiene

- `CONTRIBUTING.md`: how to build and test, that the oracle is required in
  CI, that fixtures come from `make-fixtures.sh`, the no-`Unsafe` rule,
  local fuzzing after decoder changes, English only.
- `SECURITY.md`: report privately by email (GitHub's private vulnerability
  reporting is only available on public repos).
- Repository description and topics via `gh repo edit` (`swift`, `rar`,
  `cbr`, `cbz`, `comics`, `ios`, `macos`, `swiftpm`), after Maarten approves
  the text.

## Open decisions for Maarten

1. **Error category API.** Either only the guide (doc only), or also a
   small public `RARError.category` (`.corrupt`, `.unsupported`, `.limit`,
   `.environment`) so apps do not have to copy the table. Recommendation:
   add it. It is about 30 lines plus a test that covers every case, and it
   keeps the guide and code from drifting apart.
2. **Visibility.** The repo is private, so "outside developers" cannot
   find it, and the installation snippet only works for people with access.
   This phase does not make it public. That stays Maarten's decision.
3. **Tag `0.1.0`** at the end of this phase: yes or not yet.
4. **SwiftUI example on iOS** in CI as well (one extra xcodebuild in
   `ios-build`, about +1 minute), or macOS only. Recommendation: both,
   since iOS is the real target.

## Tests and acceptance

- CI builds: the docs (`docbuild`, warnings fail), `Examples/SwiftUIConvert`
  for macOS (and iOS, see decision 4), and `ListAndExtract` as today.
- If decision 1 is yes: a test that maps every `RARError` case to its
  category. Run first against a version that maps everything to
  `.corrupt`, so it is shown to fail.
- Acceptance from #3: an integrator can start from the README and DocC
  alone, examples compile in CI, the installation snippet names a real tag
  (after decision 3), and licenses, gaps, validation stages and memory
  responsibility are readable without `CLAUDE.md`.
- Not covered by CI: whether the SwiftUI example keeps the UI responsive
  and cancels promptly. That is a manual check.

## Outcome

Done 2026-10-14.

- **`ErrorCategory`** (RARCore) with six cases rather than the four in the
  plan: `corrupt`, `unsupported`, `limit`, `io`, `cancelled`, `usage`.
  Splitting "environment" lets an app stay silent on `cancelled` without
  string matching. `usage` covers `CBZWriterError.invalidName`,
  `duplicateName` and `invalidState`, which conversion never produces from
  input. `CBZWriterError` maps `zip64Required` and `tooManyEntries` to
  `limit`. `ErrorCategoryTests` checks every case plus real errors through
  `RARReader` (garbage, truncated, encrypted, limit, bad CRC). Against a
  stub that maps everything to `.corrupt`, it failed with 10 failures.
- **README** rewritten as the entry point: installation, products with
  their licenses, quick start, support table with the two known gaps,
  validation stages, limits and memory, concurrency, error categories,
  safety, versioning. "Never traps" is now described as a result of
  testing. The "Status / phase N of 7" section and the link to `CLAUDE.md`
  are gone. Two claims were checked against the code while writing: SFX
  archives fail as `.unknownFormat` (only a signature at offset 0
  counts), and `RARReader` rejects ZIP with `.unknownFormat`.
- **DocC** catalog with a landing page, GettingStarted, Concurrency and
  Errors, plus doc comments on the public integration types. RARCore
  symbols (`Limits/...`) resolve from the SwiftRAR catalog through the
  re-export. A deliberately broken link produced a DocC warning, so the CI
  check (grep for `file:line:col: warning:` in the docbuild log) works.
- **`Examples/SwiftUIConvert`**: `ConvertUI` library (model + view) and a
  macOS app target, with `StrictConcurrency` enabled. It builds without
  warnings for macOS (`swift build`, warnings as errors) and for iOS
  (`xcodebuild`, scheme `SwiftUIConvert`, generic iOS). SwiftPM only
  creates a scheme for the executable, but building it compiles `ConvertUI`
  for iOS too.
- **CI:** `test (current)` builds the SwiftUI example; `ios-build` builds it
  for iOS and runs the DocC check.
- **Licensing:** a products-and-licenses table in the README, the same in
  `NOTICE`, and a note in `Package.swift`.
- `CHANGELOG.md` (0.1.0), `CONTRIBUTING.md`, `SECURITY.md` (private report
  to @polderpijplijn; GitHub's private reporting once the repo is public).
- **Not checked by CI or by me:** whether the SwiftUI example keeps the UI
  responsive and cancels promptly in a running app. That needs a manual run
  (`swift run --package-path Examples/SwiftUIConvert` on a Mac).
- Not done: the repository description and topics wait for Maarten's
  approval of the text.
- First CI run (38478670595) failed on the runner's Swift 6.1.2: in the
  SwiftUI example, `Task { @MainActor in self?.report(...) }` inside the
  progress closure is "sending 'self'" there, while the local 6.3.1
  accepted it. Progress now travels through an `AsyncStream` (worker
  yields, the main-actor task reads), so nothing of the model crosses
  threads and updates arrive in order. The Concurrency article shows the
  same pattern. Lesson: the local toolchain is newer than CI's `current`.
