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
// Ported from UnRAR's rarvm.cpp (Prepare, ReadData, ExecuteStandardFilter
// and the Itanium bit helpers). There is no general RarVM: only the six
// standard filter programs are recognised, as UnRAR itself does.

import RARCore

/// The RAR 3.x filters that UnRAR recognises by the CRC of their VM program.
public enum StandardFilter: String, CaseIterable, Sendable {
    case e8, e8e9, itanium, delta, rgb, audio
}

/// Outcome of recognising a filter program.
enum FilterProgram: Equatable {
    case standard(StandardFilter)
    /// The XOR checksum byte does not match: corrupt data.
    case badChecksum
    /// A valid program that is not one of the standard filters.
    case unknown
}

enum RarVM {
    /// Size of the VM memory that filters work in.
    static let memorySize = 0x40000
    static let memoryMask = memorySize - 1
    static let maxChannels = 1024

    /// UnRAR's StdList: program length and CRC32 per standard filter.
    static let standardPrograms: [(length: Int, crc: UInt32, filter: StandardFilter)] = [
        (53, 0xAD57_6887, .e8),
        (57, 0x3CD7_E57E, .e8e9),
        (120, 0x3769_893F, .itanium),
        (29, 0x0E06_077D, .delta),
        (149, 0x1C2C_5DC8, .rgb),
        (216, 0xBC85_E701, .audio),
    ]

    /// `RarVM::Prepare`: checks the XOR byte, then matches length and CRC.
    static func recognise(_ code: [UInt8]) -> FilterProgram {
        guard let first = code.first else { return .badChecksum }
        var xor: UInt8 = 0
        for byte in code.dropFirst() { xor ^= byte }
        guard xor == first else { return .badChecksum }
        let crc = CRC32.checksum(code)
        for program in standardPrograms where program.length == code.count && program.crc == crc {
            return .standard(program.filter)
        }
        return .unknown
    }

    /// `RarVM::ReadData`: a variable-length integer from the filter header.
    static func readData(_ input: inout VMBitInput) -> UInt32 {
        let data = input.peek16()
        switch data & 0xC000 {
        case 0:
            input.skip(6)
            return (data >> 10) & 0xF
        case 0x4000:
            if data & 0x3C00 == 0 {
                input.skip(14)
                return 0xFFFF_FF00 | ((data >> 2) & 0xFF)
            }
            input.skip(10)
            return (data >> 6) & 0xFF
        case 0x8000:
            input.skip(2)
            let value = input.peek16()
            input.skip(16)
            return value
        default:
            input.skip(2)
            var value = input.peek16() << 16
            input.skip(16)
            value |= input.peek16()
            input.skip(16)
            return value
        }
    }

    /// `RarVM::Execute` for a standard filter. `memory` holds the block at
    /// offset 0. Returns where the filtered data is and how long it is.
    /// Invalid parameters leave the data as is, like UnRAR.
    static func execute(_ filter: StandardFilter, registers: [UInt32], memory: inout [UInt8]) -> (offset: Int, count: Int) {
        let success = apply(filter, registers: registers, memory: &memory)
        let blockSize = Int(registers[4]) & memoryMask
        switch filter {
        case .delta, .rgb, .audio:
            return (2 * blockSize > memorySize || !success ? 0 : blockSize, blockSize)
        case .e8, .e8e9, .itanium:
            return (0, blockSize)
        }
    }

    /// `ExecuteStandardFilter`. `memory` is `memorySize + 4` bytes long, as
    /// UnRAR allocates it, so a 4-byte read at `memorySize - 4` stays inside.
    static func apply(_ filter: StandardFilter, registers r: [UInt32], memory: inout [UInt8]) -> Bool {
        switch filter {
        case .e8, .e8e9:
            let dataSize = Int(r[4])
            let fileOffset = r[6]
            guard dataSize <= memorySize, dataSize >= 4 else { return false }
            let fileSize: UInt32 = 0x100_0000
            let second: UInt8 = filter == .e8e9 ? 0xE9 : 0xE8
            var position = 0
            while position < dataSize - 4 {
                let byte = memory[position]
                position += 1
                guard byte == 0xE8 || byte == second else { continue }
                let offset = UInt32(truncatingIfNeeded: position) &+ fileOffset
                let address = read32(memory, at: position)
                if address & 0x8000_0000 != 0 {
                    if (address &+ offset) & 0x8000_0000 == 0 {
                        write32(&memory, address &+ fileSize, at: position)
                    }
                } else if (address &- fileSize) & 0x8000_0000 != 0 {
                    write32(&memory, address &- offset, at: position)
                }
                position += 4
            }

        case .itanium:
            let dataSize = Int(r[4])
            guard dataSize <= memorySize, dataSize >= 21 else { return false }
            var fileOffset = r[6] >> 4
            let masks: [UInt8] = [4, 4, 6, 6, 0, 0, 7, 7, 4, 4, 0, 0, 4, 4, 0, 0]
            var position = 0
            while position < dataSize - 21 {
                let template = Int(memory[position] & 0x1F) - 0x10
                if template >= 0 {
                    let commandMask = masks[template]
                    for slot in 0...2 where commandMask & (1 << slot) != 0 {
                        let start = slot * 41 + 5
                        if itaniumBits(memory, block: position, at: start + 37, count: 4) == 5 {
                            let target = itaniumBits(memory, block: position, at: start + 13, count: 20)
                            setItaniumBits(&memory, block: position, (target &- fileOffset) & 0xFFFFF,
                                           at: start + 13, count: 20)
                        }
                    }
                }
                position += 16
                fileOffset &+= 1
            }

        case .delta:
            let dataSize = Int(r[4])
            let channels = Int(r[0])
            guard dataSize <= memorySize / 2, channels <= maxChannels, channels > 0 else { return false }
            var source = 0
            for channel in 0..<channels {
                var previous: UInt8 = 0
                for destination in stride(from: dataSize + channel, to: dataSize * 2, by: channels) {
                    previous &-= memory[source]
                    memory[destination] = previous
                    source += 1
                }
            }

        case .rgb:
            let dataSize = Int(r[4])
            let width = Int(r[0] &- 3)
            let positionR = Int(r[1])
            guard dataSize <= memorySize / 2, dataSize >= 3, width <= dataSize, positionR <= 2 else { return false }
            let destination = dataSize
            var source = 0
            for channel in 0..<3 {
                var previous: UInt32 = 0
                for index in stride(from: channel, to: dataSize, by: 3) {
                    var predicted = previous
                    if index >= width + 3 {
                        let upper = UInt32(memory[destination + index - width])
                        let upperLeft = UInt32(memory[destination + index - width - 3])
                        predicted = previous &+ upper &- upperLeft
                        let pa = distance(predicted, previous)
                        let pb = distance(predicted, upper)
                        let pc = distance(predicted, upperLeft)
                        if pa <= pb && pa <= pc {
                            predicted = previous
                        } else if pb <= pc {
                            predicted = upper
                        } else {
                            predicted = upperLeft
                        }
                    }
                    let value = UInt8(truncatingIfNeeded: predicted &- UInt32(memory[source]))
                    source += 1
                    memory[destination + index] = value
                    previous = UInt32(value)
                }
            }
            for index in stride(from: positionR, to: dataSize - 2, by: 3) {
                let green = memory[destination + index + 1]
                memory[destination + index] &+= green
                memory[destination + index + 2] &+= green
            }

        case .audio:
            let dataSize = Int(r[4])
            let channels = Int(r[0])
            guard dataSize <= memorySize / 2, channels <= 128, channels > 0 else { return false }
            let destination = dataSize
            var source = 0
            for channel in 0..<channels {
                var previousByte: UInt32 = 0
                var previousDelta: UInt32 = 0
                var dif = [UInt32](repeating: 0, count: 7)
                var d1: Int32 = 0, d2: Int32 = 0, d3: Int32 = 0
                var k1: Int32 = 0, k2: Int32 = 0, k3: Int32 = 0
                var byteCount = 0
                for index in stride(from: channel, to: dataSize, by: channels) {
                    d3 = d2
                    d2 = Int32(bitPattern: previousDelta) &- d1
                    d1 = Int32(bitPattern: previousDelta)

                    var predicted = 8 &* previousByte
                        &+ UInt32(bitPattern: k1 &* d1)
                        &+ UInt32(bitPattern: k2 &* d2)
                        &+ UInt32(bitPattern: k3 &* d3)
                    predicted = (predicted >> 3) & 0xFF

                    let current = memory[source]
                    source += 1
                    predicted &-= UInt32(current)
                    memory[destination + index] = UInt8(truncatingIfNeeded: predicted)
                    let delta = Int8(truncatingIfNeeded: predicted &- previousByte)
                    previousDelta = UInt32(bitPattern: Int32(delta))
                    previousByte = predicted

                    let d = Int32(bitPattern: UInt32(bitPattern: Int32(Int8(bitPattern: current))) << 3)
                    dif[0] &+= d.magnitude
                    dif[1] &+= (d &- d1).magnitude
                    dif[2] &+= (d &+ d1).magnitude
                    dif[3] &+= (d &- d2).magnitude
                    dif[4] &+= (d &+ d2).magnitude
                    dif[5] &+= (d &- d3).magnitude
                    dif[6] &+= (d &+ d3).magnitude

                    if byteCount & 0x1F == 0 {
                        var minimum = dif[0]
                        var minimumIndex = 0
                        dif[0] = 0
                        for j in 1..<dif.count {
                            if dif[j] < minimum {
                                minimum = dif[j]
                                minimumIndex = j
                            }
                            dif[j] = 0
                        }
                        switch minimumIndex {
                        case 1: if k1 >= -16 { k1 -= 1 }
                        case 2: if k1 < 16 { k1 += 1 }
                        case 3: if k2 >= -16 { k2 -= 1 }
                        case 4: if k2 < 16 { k2 += 1 }
                        case 5: if k3 >= -16 { k3 -= 1 }
                        case 6: if k3 < 16 { k3 += 1 }
                        default: break
                        }
                    }
                    byteCount += 1
                }
            }
        }
        return true
    }

    // MARK: - Helpers

    private static func distance(_ a: UInt32, _ b: UInt32) -> UInt32 {
        Int32(bitPattern: a &- b).magnitude
    }

    private static func read32(_ memory: [UInt8], at index: Int) -> UInt32 {
        UInt32(memory[index]) | UInt32(memory[index + 1]) << 8
            | UInt32(memory[index + 2]) << 16 | UInt32(memory[index + 3]) << 24
    }

    private static func write32(_ memory: inout [UInt8], _ value: UInt32, at index: Int) {
        for byte in 0..<4 {
            memory[index + byte] = UInt8(truncatingIfNeeded: value >> UInt32(8 * byte))
        }
    }

    /// `FilterItanium_GetBits` within the 16-byte bundle at `block`.
    private static func itaniumBits(_ memory: [UInt8], block: Int, at bitPosition: Int, count: Int) -> UInt32 {
        let field = read32(memory, at: block + bitPosition / 8) >> UInt32(bitPosition & 7)
        return field & (0xFFFF_FFFF >> UInt32(32 - count))
    }

    /// `FilterItanium_SetBits` within the 16-byte bundle at `block`.
    private static func setItaniumBits(_ memory: inout [UInt8], block: Int, _ value: UInt32, at bitPosition: Int, count: Int) {
        let address = block + bitPosition / 8
        let shift = UInt32(bitPosition & 7)
        var andMask = ~((0xFFFF_FFFF >> UInt32(32 - count)) << shift)
        var field = value << shift
        for byte in 0..<4 {
            memory[address + byte] &= UInt8(truncatingIfNeeded: andMask)
            memory[address + byte] |= UInt8(truncatingIfNeeded: field)
            andMask = (andMask >> 8) | 0xFF00_0000
            field >>= 8
        }
    }
}

/// UnRAR's `BitInput` over a filter header: MSB-first, zeros past the end.
struct VMBitInput {
    /// UnRAR copies at most this much filter code into its bit input.
    static let maxSize = 0x8000

    private let bytes: [UInt8]
    private(set) var bitPosition = 0

    init(_ code: [UInt8]) {
        bytes = Array(code.prefix(Self.maxSize))
    }

    /// Byte address of the read position (UnRAR's `InAddr`).
    var byteAddress: Int { bitPosition >> 3 }

    /// `fgetbits`: the next 16 bits, without consuming them.
    func peek16() -> UInt32 {
        let address = byteAddress
        var field: UInt32 = 0
        for index in address..<(address + 3) {
            field = field << 8 | UInt32(index < bytes.count ? bytes[index] : 0)
        }
        return (field >> UInt32(8 - (bitPosition & 7))) & 0xFFFF
    }

    /// `faddbits`.
    mutating func skip(_ count: Int) {
        bitPosition += count
    }

    /// `Overflow`: whether reading `count` more bytes would leave UnRAR's buffer.
    func overflows(_ count: Int) -> Bool {
        byteAddress + count >= Self.maxSize
    }
}
