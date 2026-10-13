# ``SwiftRAR``

Read RAR4 and RAR5 archives and convert CBR comics to CBZ, in pure Swift.

## Overview

SwiftRAR lists and extracts the files of RAR archives and converts CBR
(RAR) comic archives into CBZ (stored ZIP) files. It is written entirely in
Swift: no C or C++, no libarchive, no other dependencies.

- RAR4 compression (LZ, the standard filters, PPMd) and RAR5 compression
  (LZ and its filters), solid or not.
- Streaming I/O: the archive is never loaded into memory as a whole.
- A required ``Limits`` value on every call bounds sizes, counts,
  dictionary and model memory.
- Every entry's CRC32 is verified. Output names are sanitised.
- Cooperative cancellation and progress.

SwiftRAR is a reader only. It never creates RAR archives.

## Topics

### Essentials

- <doc:GettingStarted>
- ``convertToCBZ(from:to:limits:progress:)``
- ``RARReader``

### Guides

- <doc:Concurrency>
- <doc:Errors>

### Conversion

- ``convertToCBZ(from:to:limits:progress:)``
- ``convertToCBZ(source:output:limits:progress:)``
- ``ConversionResult``

### Reading single files

- ``RARReader``
