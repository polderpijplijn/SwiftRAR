# Phase 7: trustworthy CI (issue #3, P0)

Status: approved 2026-10-13. Section 1 done; section 3 reduced (see there);
section 2 done; section 3 (differential check) next.

Issue #3 P0 step 1 (the `UInt8` literal that broke CI) is done in 539cdf2.
This phase covers the rest of P0, which also is roadmap phase 7:

1. a toolchain matrix plus an iOS build check, and a Swift 6 strict
   concurrency assessment;
2. a required oracle job whose success proves the oracle comparisons ran;
3. ~~bounded, scheduled fuzzing in CI~~ dropped; a one-off local
   differential check against the pinned UnRAR oracle instead.

Everything else in #3 (extraction facade, documentation, licensing table,
compatibility, benchmarks) stays out of this phase.

## Cost constraint

The repository is private. GitHub bills macOS minutes at 10x. Per-push work
on macOS stays small: one job per toolchain plus one iOS build.

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

## 3. Fuzzing: no CI schedule (decided 2026-10-13)

Maarten decided against scheduled fuzzing in CI. The code only changes when
it is worked on, the harness has run after every phase without a finding,
and a nightly run on unchanged code mostly costs minutes. What stays:

- The existing rule in `CLAUDE.md`: fuzz locally (`Fuzz/build.sh run`)
  after every decoder change and before a new copy goes into Grim Reader.
  Any `crash-*` file becomes a regression test.
- A one-off **differential check**, run by hand: every input in the fuzz
  corpus goes through `convertToCBZ` and through the pinned unrar
  (`unrar p -inul` per entry). A finding is SwiftRAR accepting what unrar
  rejects, or both accepting with different bytes. SwiftRAR refusing what
  unrar accepts (limits, unsupported features) is only counted. This catches
  silent wrong output, which the crash-only fuzzer cannot. The tool lives in
  the `Fuzz` package as `SwiftRARDiff` if it is worth keeping, otherwise
  as a script in the scratchpad; the outcome is recorded below either way.

Issue #3 gets a comment that scheduled fuzzing is left out on purpose, and
why.

## Files

- `.github/workflows/ci.yml`: matrix, iOS build, strict concurrency (done);
  required-oracle leg with cached oracle.
- `Tests/SwiftRARTests/Support/Oracle.swift` and the skip sites in
  `FixtureTests`, `FilterTests`, `PPMdTests`, `Unpack29Tests`: skip-or-fail.
- `CLAUDE.md`: next step, roadmap.

## Order of work

1. Matrix, iOS build, strict concurrency (done, 2d5d10d).
2. Skip-or-fail helper, proved against the hidden oracle locally; then the
   CI leg.
3. Differential check by hand.
4. Comment on #3 with what P0 now covers; #3 stays open for P1/P2.

## Acceptance (from #3, as adjusted)

- Supported toolchains pass.
- At least one required job reports non-skipped oracle comparisons.
- Scheduled fuzzing: left out on purpose (section 3).

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

### Section 2 (2026-10-13)

- `Tools.unavailable(_:)` in `Support/Oracle.swift` returns an `XCTSkip`,
  or under `SWIFTRAR_REQUIRE_ORACLE=1` an error that fails the test. All ten
  skip sites use it (missing unrar, bsdtar, unzip, fixtures, and the
  fixture-shape guards in `FilterTests` and `Unpack29Tests`).
- Proof, with the local oracle moved aside and the variable set: before the
  change 26 oracle-suite tests ran with 3 skipped and 0 failures; after it,
  the same 3 failed. With the oracle present and the variable set, the full
  suite ran 139 tests, 0 failures, 0 skipped.
- CI: the `current` leg caches `Tools/oracle/.build` (key: hash of
  `build-unrar.sh`, which pins version and checksum), builds the oracle
  without `continue-on-error`, and sets `SWIFTRAR_REQUIRE_ORACLE=1`.
  `test (current)` is the check to make required in branch protection.
