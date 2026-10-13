// SPDX-License-Identifier: MIT

/// Archive format, recognised by the magic bytes at the start of the source.
public enum ArchiveFormat: Equatable, Sendable {
    case zip
    case rar4
    case rar5

    static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    static let rar4Magic: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    static let rar5Magic: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
    static let rar14Magic: [UInt8] = [0x52, 0x45, 0x7E, 0x5E]

    /// Length of the RAR signature; the first header starts right after it.
    var signatureLength: Int {
        switch self {
        case .zip: return 0
        case .rar4: return Self.rar4Magic.count
        case .rar5: return Self.rar5Magic.count
        }
    }

    /// Detects the format. Only a signature at offset 0 counts; SFX archives
    /// (with an executable stub in front) are deliberately unsupported.
    public static func detect(_ source: ByteSource) throws -> ArchiveFormat {
        let headLength = Int(min(source.size, 8))
        let head = try source.read(at: 0, count: headLength)
        if head.starts(with: zipMagic) { return .zip }
        if head.starts(with: rar5Magic) { return .rar5 }
        if head.starts(with: rar4Magic) { return .rar4 }
        if head.starts(with: rar14Magic) { throw RARError.unsupportedFormat("RAR 1.4") }
        if head.starts(with: rar4Magic.prefix(6)) {
            // "Rar!\x1A\x07" followed by an unknown version byte.
            throw RARError.unsupportedFormat("unknown RAR version")
        }
        throw RARError.unknownFormat
    }
}
