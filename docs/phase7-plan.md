# Phase 7: trustworthy CI (issue #3, P0)

Status: approved 2026-10-13 (Linux for fuzzing); section 1 in progress.

Issue #3 P0 step 1 (the `UInt8` literal that broke CI) is done in 539cdf2.
This phase covers the rest of P0, which also is roadmap phase 7:

1. a toolchain matrix plus an iOS build check, and a Swift 6 strict
   concurrency assessment;
2. a required oracle job whose success proves the oracle comparisons ran;
3. bounded, scheduled fuzzing with retained crash inputs and a differential
   check against the pinned UnRAR oracle.

Everything else in #3 (extraction facade, documentation, licensing table,
compatibility, benchmarks) stays out of this phase.

## Cost constraint

The repository is private. GitHub bills macOS minutes at 10x and Linux at
1x. The current single macOS job is fine; three macOS jobs on every push plus
a nightly 30-minute macOS fuzz run would use up the free allowance within
days. The plan therefore:

- keeps per-push work on macOS small (one job per toolchain, oracle built once
  and cached);
- runs fuzzing on **Linux** (`swift:6.x` container, where `-sanitize=fuzzer`
  works out of the box with no toolchain install), if the package builds on
  Linux. The sources only import Foundation, so it should; step 4 checks it.
  If Linux turns out to be impractical, fall back to a weekly macOS run with a
  short time budget, not the Mac mini (self-hosted runners have overloaded it
  before).

## 1. Toolchain matrix and iOS build (`ci.yml`)

- `test` job as a matrix:
  - **oldest:** `macos-14` with Xcode 15.x (Swift 5.9/5.10), matching
    `swift-tools-version:5.9`; `xcode-select` the exact Xcode in a step.
  - **current:** `macos-15` with the latest Xcode on the image.
- `ios-build` job: `xcodebuild build -scheme SwiftRAR
  -destination 'generic/platform=iOS'`. A generic destination compiles
  for the device SDK; no simulator is booted.
- Strict concurrency: build once locally with
  `-Xswiftc -strict-concurrency=complete` and record the warnings in the
  outcome section. If they are few and mechanical, fix them and add a CI step
  that builds with `-strict-concurrency=complete -warnings-as-errors`. If not,
  record them and leave the fix to a separate issue: no `Sendable` or actor
  redesign in this phase.

## 2. Required oracle job

Today the oracle build has `continue-on-error: true`, and every test that
needs it throws `XCTSkip`, so a green run says nothing about comparisons.

- Tests: when `SWIFTRAR_REQUIRE_ORACLE=1` is set, `Tools.requireUnrar()` and
  the "fixture missing" guards fail the test instead of skipping it. One helper
  (`Tools.skipOrFail`) so the rule lives in one place. Without the variable,
  local runs behave as now.
- CI: the `current` matrix leg builds the oracle **without**
  `continue-on-error`, caches `Tools/oracle/.build` keyed on the pinned
  UnRAR version, and runs `swift test` with `SWIFTRAR_REQUIRE_ORACLE=1`. That
  leg is the one to mark required in branch protection (a manual GitHub
  setting; I will name it, not change it).
- The `oldest` leg runs without the oracle, skips allowed.

Proof that the variable works: run the suite locally with the variable set and
the oracle hidden (`SWIFTRAR_UNRAR=/nonexistent`, local build moved aside):
it must fail. Then with the oracle: it must pass with zero oracle skips.

## 3. Scheduled fuzzing (`fuzz.yml`)

- Triggers: `schedule` (nightly) and `workflow_dispatch` with a duration
  input. Default budget 20 minutes (`-max_total_time=1200`).
- Corpus: seeded from `Tests/Fixtures/*.rar` plus `Fuzz/corpus`, carried
  between runs with `actions/cache`. Merged (`-merge=1`) at the end so it
  does not grow without bound.
- Crash inputs: `-artifact_prefix=artifacts/`; on failure the job uploads
  `artifacts/` and fails. Reproduce with `Fuzz/build.sh` and then
  `SwiftRARFuzz <crash-file>`; the README gets those two lines.
- Fixed crashes become regression tests: the crash file goes into
  `Tests/Fixtures/regressions/`, and one test runs every file there through
  `RARArchive` and `convertToCBZ` and expects a result or a thrown error.
  That test is added now, with an empty directory, so the route exists.
- `Fuzz/build.sh` learns Linux: on Linux it uses the toolchain on PATH
  instead of looking for an `.xctoolchain`.

### Differential check

libFuzzer cannot call unrar per input cheaply, so the differential check runs
after the fuzz run, over the merged corpus:

- New executable `SwiftRARDiff` in the `Fuzz` package (normal build, no
  sanitizers): for each input, run `convertToCBZ` into memory and
  `unrar p -inul` per entry, and compare.
- It fails on: SwiftRAR succeeds where unrar reports an error, or both
  succeed and the bytes differ. SwiftRAR refusing what unrar accepts is
  expected (limits, unsupported features) and only counted in the summary.
- Mismatching inputs are uploaded like crash inputs.
- The oracle is the same pinned UnRAR 7.3.1 source, built on Linux by
  `build-unrar.sh` (its makefile builds on Linux as is).

## Files

- `.github/workflows/ci.yml`: matrix, oracle cache, required-oracle leg,
  iOS build (and the strict-concurrency step if section 1 allows).
- `.github/workflows/fuzz.yml`: new.
- `Tests/SwiftRARTests/Support/Oracle.swift` and the guards in
  `FixtureTests`, `FilterTests`, `PPMdTests`, `Unpack29Tests`: skip-or-fail.
- `Tests/SwiftRARTests/RegressionTests.swift` + `Tests/Fixtures/regressions/`.
- `Fuzz/Package.swift`, `Fuzz/Sources/SwiftRARDiff/`, `Fuzz/build.sh`.
- `README.md` (reproduce a crash), `CLAUDE.md` (next step, roadmap).

## Order of work

1. Skip-or-fail helper, proved against the hidden oracle locally.
2. Regression test with its (empty) directory.
3. `ci.yml` matrix and iOS build; push and read the run.
4. Linux check: the fuzz workflow first only builds the package and the
   harness on Linux (`workflow_dispatch`), then fuzzing, then the
   differential step. Run it once by hand with a short budget.
5. Strict-concurrency assessment, recorded below.
6. Comment on #3 with what P0 now covers; #3 stays open for P1/P2.

## Acceptance (from #3)

- Supported toolchains pass.
- At least one required job reports non-skipped oracle comparisons.
- Fuzz failures produce reproducible regression artifacts.

## Outcome

### Section 1 (2026-10-13)

- Strict concurrency: library and tests build without a single warning under
  `-strict-concurrency=complete -warnings-as-errors`, and the library also
  in Swift 6 language mode (local Swift 6.3.1). So the check went straight
  into CI as a step of the `current` leg; nothing needed fixing.
- iOS: `xcodebuild build -scheme SwiftRAR -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO` succeeds locally; it is the `ios-build` job.
- Matrix: `oldest` is macos-14 with Xcode 15.2 (Swift 5.9.2, no oracle);
  `current` is macos-15 with the image's default Xcode and the oracle.
