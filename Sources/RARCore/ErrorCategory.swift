// SPDX-License-Identifier: MIT

/// What kind of failure an error is, so an app can decide what to tell the
/// user without matching every case.
public enum ErrorCategory: Equatable, Sendable {
    /// The input is damaged or not an archive. Retrying will not help.
    case corrupt
    /// A valid archive that uses a feature SwiftRAR does not support
    /// (encryption, multiple volumes, an unsupported method or checksum).
    case unsupported
    /// A bound in `Limits`, or a format limit of the output (no ZIP64), was
    /// exceeded. Retrying with looser `Limits` may work, if the app allows it.
    case limit
    /// Reading or writing a file failed. Retrying may help.
    case io
    /// The task was cancelled. Usually nothing to report.
    case cancelled
    /// The API was called incorrectly, e.g. `CBZWriter` calls in the wrong
    /// order. Conversion never produces this from input; it means a bug.
    case usage
}

extension RARError {
    /// The kind of failure; see `ErrorCategory`.
    public var category: ErrorCategory {
        switch self {
        case .unknownFormat, .truncated, .corruptHeader, .corruptData,
             .badHeaderCRC, .badDataCRC, .invalidEntryName,
             .duplicateEntryName, .emptyArchive:
            return .corrupt
        case .unsupportedFormat, .encrypted, .multiVolume,
             .unsupportedCompression, .missingChecksum:
            // missingChecksum: RAR4 always has a CRC32; a RAR5 entry without
            // one is checked by BLAKE2sp only, which SwiftRAR does not verify.
            return .unsupported
        case .limitExceeded:
            return .limit
        case .io:
            return .io
        case .cancelled:
            return .cancelled
        }
    }
}
