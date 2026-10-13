# Contributing to SwiftRAR

Thanks for helping. Please open an issue before a larger change, so the
approach can be agreed first.

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

Do not open a public issue for a vulnerability; see [SECURITY.md](SECURITY.md).
