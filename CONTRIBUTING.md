# Contributing to SwiftRAR

SwiftRAR is developed in the open, but it does not take outside
contributions: pull requests are turned off, and only collaborators can
open issues. You are welcome to fork it under its licenses (see the
README). Report a vulnerability privately as described in
[SECURITY.md](SECURITY.md).

The rest of this file is for the maintainers.

## Build and test

```sh
swift build
swift test
```

The full suite takes a few minutes in debug; the PPMd fixtures dominate.
Many tests compare SwiftRAR's output with the official `unrar`. Build that
oracle with `Tools/oracle/build-unrar.sh`, or point `SWIFTRAR_UNRAR` at an
existing binary. Set `SWIFTRAR_REQUIRE_ORACLE=1` to make a missing oracle
fail the tests instead of skipping them; CI does this.

CI also checks Swift 6 strict concurrency, the iOS build, both samples in
`Examples/` and the DocC documentation (warnings fail).

## Rules

- **Licence split.** Code ported from UnRAR goes only into
  `Sources/RARDecode`, which is under the unRAR license. Everything else is
  MIT and must not contain UnRAR-derived code. Never commit the UnRAR
  source, and never add anything that creates or compresses RAR archives.
- **No `Unsafe*` pointers** in the package.
- **Never trap on input.** Check every offset and length taken from an
  archive, use overflow-checked arithmetic, and throw a `RARError`. No
  force unwraps or unchecked subscripts on input-derived values.
- **Fixtures** are committed and made by `Tools/fixtures/make-fixtures.sh`
  with pinned official `rar` versions. A new decoder path needs a fixture
  or a test that reaches it, and the test must fail without the fix.
- **Fuzz** after every decoder change: `Fuzz/build.sh run` (needs the
  swift.org toolchain, see the README). Any crash input becomes a
  regression test.
- Everything in the repository is written in English.

## Security issues

Vulnerabilities are reported privately; see [SECURITY.md](SECURITY.md).
