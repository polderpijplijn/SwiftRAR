# Changelog

All notable changes to SwiftRAR. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org); while the version is 0.x,
a minor release may change the API.

## Unreleased

### Fixed

- Create `FileOutput` files atomically and exclusively, rejecting existing
  paths (including dangling symlinks) and avoiding a symlink race when
  opening the output (#5).
- Check the remaining RAR5 header budget before reading or allocating a
  complete header (#5).
- Reject entries from another `RARReader` even when their metadata or
  archive contents are identical; entry equality includes the reader (#5).

### Changed

- The minimum toolchain is now Swift 6.2 (Xcode 26), up from Swift 5.9
  (Xcode 15.2); the package builds in the Swift 6 language mode. Platforms
  stay iOS 16 and macOS 13.

## 0.1.0 - 2026-10-14

First tagged release. RARDecode follows UnRAR 7.3.1.

### Added

- `convertToCBZ(from:to:limits:progress:)` and
  `convertToCBZ(source:output:limits:progress:)`: convert RAR4/RAR5 to a
  stored ZIP, validating the whole archive before writing; ZIP input is
  copied unchanged and not validated.
- `RARReader`: list the files of a RAR archive and extract them one at a
  time (`extract(_:into:)`, `data(for:)`), with random access in non-solid
  archives and restart points in solid ones.
- Decompression: RAR4 LZ (unpack29), the six standard RarVM filters,
  PPMd variant H, solid archives; RAR5 LZ (RAR 5.0 and 7.0 algorithms) and
  its four filters.
- `RARCore`: format detection, RAR4/RAR5 header parsing, `RARArchive`,
  stored-entry extraction, name sanitising, CRC32, `Limits`, `RARError`.
- `CBZWriter`: streaming stored-ZIP writer with UTF-8 names, no ZIP64.
- `Limits` on every call (entries, sizes, ratio, name length, dictionary,
  PPMd memory, header bytes), cooperative cancellation and progress.
- `ErrorCategory` and `category` on `RARError` and `CBZWriterError`.
- DocC documentation, an error guide, a concurrency contract, and two
  samples (`Examples/ListAndExtract`, `Examples/SwiftUIConvert`).

### Known gaps

- RAR4 names with the Unicode flag use the legacy name.
- RAR5 entries checked by BLAKE2sp only are rejected (`missingChecksum`).
- Not supported: encryption, multi-volume archives, RAR 2.x compression,
  non-standard RarVM programs, RAR 1.4, SFX, ZIP64 output.
