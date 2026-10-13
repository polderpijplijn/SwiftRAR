# Handling errors

Which errors exist, what they mean, and what to tell the user.

## Overview

Reading and conversion throw `RARError`. Conversion can also throw
`CBZWriterError`, from writing the ZIP. Both have a `category` that groups
the cases by what an app should do, so you do not have to match every case.

```swift
do {
    try convertToCBZ(from: cbr, to: cbz, limits: .default)
} catch let error as RARError where error.category == .cancelled {
    // The user stopped it: nothing to report.
} catch {
    let category = (error as? RARError)?.category ?? (error as? CBZWriterError)?.category
    show(message(for: category))
}
```

## Categories

| Category | Meaning | What to do |
|----------|---------|------------|
| `corrupt` | Damaged, truncated or not an archive | Report a damaged file. Retrying will not help. |
| `unsupported` | A valid archive using a feature SwiftRAR does not support | Report that it is not supported. Another tool may open it. |
| `limit` | A bound in `Limits` or a ZIP format limit was exceeded | Report that it is too large, or retry with looser `Limits` if the app allows it. |
| `io` | Reading or writing a file failed | Report it. A retry may help (disk space, permissions). |
| `cancelled` | The task was cancelled | Usually nothing. |
| `usage` | The API was called incorrectly | A bug in the calling code. Conversion never produces this from input. |

## RARError

| Case | Category | When |
|------|----------|------|
| `unknownFormat` | corrupt | Not RAR or ZIP, or a ZIP given to `RARReader` |
| `truncated` | corrupt | The input ends too early |
| `corruptHeader` | corrupt | A header is inconsistent |
| `corruptData` | corrupt | The compressed data is malformed |
| `badHeaderCRC` | corrupt | A header checksum does not match |
| `badDataCRC` | corrupt | An entry's CRC32 does not match its contents |
| `invalidEntryName` | corrupt | A name is empty after sanitising, or has control characters |
| `duplicateEntryName` | corrupt | Two names are the same after sanitising |
| `emptyArchive` | corrupt | No extractable file |
| `unsupportedFormat` | unsupported | RAR 1.4, an unknown RAR5 algorithm version, or an unknown size |
| `encrypted` | unsupported | A password-protected archive or entry |
| `multiVolume` | unsupported | Part of a multi-volume set |
| `unsupportedCompression` | unsupported | RAR 2.x compression, or a non-standard RarVM filter |
| `missingChecksum` | unsupported | A RAR5 entry checked by BLAKE2sp only (`rar -htb`) |
| `limitExceeded` | limit | The associated `Limits.Kind` says which bound |
| `io` | io | Opening, reading or replacing a file failed |
| `cancelled` | cancelled | The surrounding task was cancelled |

## CBZWriterError

| Case | Category | When |
|------|----------|------|
| `zip64Required` | limit | The CBZ would reach 4 GiB (ZIP64 is not written) |
| `tooManyEntries` | limit | More than 65,534 entries |
| `io` | io | Writing the output failed |
| `invalidName`, `duplicateName`, `invalidState` | usage | Direct `CBZWriter` use with a bad name or calls out of order |

## After an error

- ``convertToCBZ(from:to:limits:progress:)`` deletes its temporary file
  and leaves an existing destination untouched.
- ``convertToCBZ(source:output:limits:progress:)`` leaves partial data in
  `output`; discard it.
- ``RARReader/extract(_:into:)``: discard what the sink received. The reader
  stays usable.
