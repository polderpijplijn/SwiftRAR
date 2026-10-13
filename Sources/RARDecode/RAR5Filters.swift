// This target (RARDecode) is licensed under the unRAR license, not MIT.
// See LICENSE-UNRAR in this directory. Required notice from that license:
//
//   UnRAR source code may be used in any software to handle
//   RAR archives without limitations free of charge, but cannot be
//   used to develop RAR (WinRAR) compatible archiver and to
//   re-create RAR compression algorithm, which is proprietary.
//   Distribution of modified UnRAR source code in separate form
//   or as a part of other software is permitted, provided that
//   full text of this paragraph, starting from "UnRAR source code"
//   words, is included in license, or in documentation if license
//   is not available, and in source code comments of resulting package.
//
// Decompression only. Nothing in this target may be used to create or
// compress RAR archives.
//
// Ported from UnRAR's unpack50.cpp (Unpack::ApplyFilter).

/// The filters of the RAR5 format, numbered as in the bitstream.
public enum RAR5Filter: Int, CaseIterable, Sendable {
    case delta = 0, e8, e8e9, arm
}

enum RAR5Filters {
    /// `ApplyFilter`: undoes `filter` on one block. `fileOffset` is the
    /// position of the block in the entry (UnRAR's WrittenFileSize).
    static func apply(_ filter: RAR5Filter, channels: Int, fileOffset: UInt64, to data: [UInt8]) -> [UInt8] {
        switch filter {
        case .e8, .e8e9:
            return e8(data, fileOffset: UInt32(truncatingIfNeeded: fileOffset), alsoE9: filter == .e8e9)
        case .arm:
            return arm(data, fileOffset: UInt32(truncatingIfNeeded: fileOffset))
        case .delta:
            return delta(data, channels: channels)
        }
    }

    /// x86 CALL (and JMP) targets: absolute addresses back to relative ones.
    static func e8(_ input: [UInt8], fileOffset: UInt32, alsoE9: Bool) -> [UInt8] {
        var data = input
        let fileSize: UInt32 = 0x100_0000
        let second: UInt8 = alsoE9 ? 0xE9 : 0xE8
        var position = 0
        // `position + 4 < count`, so blocks shorter than 5 bytes stay as is.
        while position + 4 < data.count {
            let byte = data[position]
            position += 1
            guard byte == 0xE8 || byte == second else { continue }
            let offset = (UInt32(truncatingIfNeeded: position) &+ fileOffset) % fileSize
            let address = read32(data, at: position)
            if address & 0x8000_0000 != 0 {
                if (address &+ offset) & 0x8000_0000 == 0 {
                    write32(&data, address &+ fileSize, at: position)
                }
            } else if (address &- fileSize) & 0x8000_0000 != 0 {
                write32(&data, address &- offset, at: position)
            }
            position += 4
        }
        return data
    }

    /// ARM BL instructions: 24-bit word offsets.
    static func arm(_ input: [UInt8], fileOffset: UInt32) -> [UInt8] {
        var data = input
        var position = 0
        while position + 3 < data.count {
            if data[position + 3] == 0xEB {
                var offset = UInt32(data[position]) | UInt32(data[position + 1]) << 8 | UInt32(data[position + 2]) << 16
                offset &-= (fileOffset &+ UInt32(truncatingIfNeeded: position)) / 4
                data[position] = UInt8(truncatingIfNeeded: offset)
                data[position + 1] = UInt8(truncatingIfNeeded: offset >> 8)
                data[position + 2] = UInt8(truncatingIfNeeded: offset >> 16)
            }
            position += 4
        }
        return data
    }

    /// Bytes of each channel are stored together as differences; put them
    /// back interleaved.
    static func delta(_ data: [UInt8], channels: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count)
        var source = 0
        for channel in 0..<channels {
            var previous: UInt8 = 0
            var destination = channel
            while destination < data.count {
                previous &-= data[source]
                output[destination] = previous
                source += 1
                destination += channels
            }
        }
        return output
    }

    private static func read32(_ data: [UInt8], at index: Int) -> UInt32 {
        UInt32(data[index]) | UInt32(data[index + 1]) << 8 | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }

    private static func write32(_ data: inout [UInt8], _ value: UInt32, at index: Int) {
        for byte in 0..<4 {
            data[index + byte] = UInt8(truncatingIfNeeded: value >> UInt32(8 * byte))
        }
    }
}
