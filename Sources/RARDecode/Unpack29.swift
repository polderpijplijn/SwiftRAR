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
// Ported from UnRAR's unpack30.cpp (Unpack29, ReadTables30, ReadEndOfBlock)
// and unpackinline.cpp (CopyString, InsertOldDist). Filters (RarVM) and PPMd
// blocks are not supported yet and end decoding with .unsupportedCompression.

import RARCore

/// RAR 2.9/3.x LZ + Huffman decoder for one non-solid entry.
struct Unpack29 {
    // Alphabet sizes: literals/lengths, distances, low distance bits,
    // repeated-distance lengths, and the bit-length alphabet.
    static let literalCount = 299
    static let distanceCount = 60
    static let lowDistanceCount = 17
    static let repeatCount = 28
    static let bitLengthCount = 20
    static let tableSize = literalCount + distanceCount + lowDistanceCount + repeatCount

    static let lowDistanceRepeat = 16
    /// UnRAR allocates at least this much window, whatever the header says.
    static let minimumWindow = 0x40000
    /// More than the longest match (255 + 32 in PPMd, 257 + 5 in LZ).
    static let matchMargin = 0x1000

    static let lengthBase: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28,
                                    32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224]
    static let lengthBits: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5]
    static let shortBase: [Int] = [0, 4, 8, 16, 32, 64, 128, 192]
    static let shortBits: [Int] = [2, 2, 3, 4, 5, 6, 6, 6]

    /// Distance slot -> (base, extra bits), from UnRAR's DBitLengthCounts.
    static let distanceSlots: (base: [Int], bits: [Int]) = {
        let slotsPerBitLength = [4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 14, 0, 12]
        var base: [Int] = []
        var bits: [Int] = []
        var distance = 0
        for (bitLength, slots) in slotsPerBitLength.enumerated() {
            for _ in 0..<slots {
                base.append(distance)
                bits.append(bitLength)
                distance += 1 << bitLength
            }
        }
        return (base, bits)
    }()

    private let method: Int
    private var input: StreamBitReader
    private let outputSize: UInt64

    private var window: [UInt8]
    private let mask: Int
    private let flushThreshold: Int
    /// Next write position in the window (UnRAR's UnpPtr).
    private var position = 0
    /// Bytes produced into the window so far.
    private var produced: UInt64 = 0
    /// Bytes handed to the sink so far (at most `outputSize`).
    private var written: UInt64 = 0
    /// Window position of the first byte not yet handed to the sink.
    private var flushPosition = 0
    private var pending = 0

    /// Larger than any window, so an unset distance copies zeros.
    private var oldDistances = [Int](repeating: Int(UInt32.max), count: 4)
    private var lastLength = 0
    private var previousLowDistance = 0
    private var lowDistanceRepeatCount = 0
    private var oldTable = [UInt8](repeating: 0, count: tableSize)

    private var literals = HuffmanTable.empty
    private var distances = HuffmanTable.empty
    private var lowDistances = HuffmanTable.empty
    private var repeats = HuffmanTable.empty

    init(method: Int, input: StreamBitReader, outputSize: UInt64, dictionarySize: UInt64) throws {
        guard dictionarySize <= UInt64(Int.max / 2) else { throw RARError.limitExceeded(.dictionarySize) }
        var size = Self.minimumWindow
        while size < Int(dictionarySize) { size <<= 1 }
        self.method = method
        self.input = input
        self.outputSize = outputSize
        self.window = [UInt8](repeating: 0, count: size)
        self.mask = size - 1
        self.flushThreshold = min(size - Self.matchMargin, 1 << 20)
    }

    mutating func run(into sink: ([UInt8]) throws -> Void) throws {
        if outputSize > 0 {
            try readTables()
        }
        decoding: while produced < outputSize {
            if pending >= flushThreshold { try flush(into: sink) }

            let number = try literals.decodeSymbol(from: &input)
            switch number {
            case 0..<256:
                window[position] = UInt8(number)
                position = (position + 1) & mask
                produced += 1
                pending += 1

            case 256:
                if try !readEndOfBlock() { break decoding }

            case 257:
                // RarVM filter: phase 3.
                throw RARError.unsupportedCompression(method: method)

            case 258:
                if lastLength != 0 { try copy(length: lastLength, distance: oldDistances[0]) }

            case 259..<263:
                let slot = number - 259
                let distance = oldDistances[slot]
                for index in stride(from: slot, to: 0, by: -1) {
                    oldDistances[index] = oldDistances[index - 1]
                }
                oldDistances[0] = distance
                let lengthSlot = try repeats.decodeSymbol(from: &input)
                guard lengthSlot < Self.repeatCount else { throw RARError.corruptData("length slot \(lengthSlot)") }
                let length = Self.lengthBase[lengthSlot] + 2 + (try readBits(Self.lengthBits[lengthSlot]))
                lastLength = length
                try copy(length: length, distance: distance)

            case 263..<271:
                let slot = number - 263
                let distance = Self.shortBase[slot] + 1 + (try readBits(Self.shortBits[slot]))
                insertOldDistance(distance)
                lastLength = 2
                try copy(length: 2, distance: distance)

            case 271..<Self.literalCount:
                let slot = number - 271
                var length = Self.lengthBase[slot] + 3 + (try readBits(Self.lengthBits[slot]))
                let distance = try readDistance()
                if distance >= 0x2000 {
                    length += 1
                    if distance >= 0x40000 { length += 1 }
                }
                insertOldDistance(distance)
                lastLength = length
                try copy(length: length, distance: distance)

            default:
                throw RARError.corruptData("literal symbol \(number)")
            }
        }
        try flush(into: sink)
        guard written == outputSize else { throw RARError.truncated }
    }

    // MARK: - Symbols

    private mutating func readBits(_ count: Int) throws -> Int {
        Int(try input.readBits(count))
    }

    private mutating func readDistance() throws -> Int {
        let slot = try distances.decodeSymbol(from: &input)
        guard slot < Self.distanceCount else { throw RARError.corruptData("distance slot \(slot)") }
        var distance = Self.distanceSlots.base[slot] + 1
        let bits = Self.distanceSlots.bits[slot]
        guard bits > 0 else { return distance }
        guard slot > 9 else { return distance + (try readBits(bits)) }

        if bits > 4 {
            distance += (try readBits(bits - 4)) << 4
        }
        if lowDistanceRepeatCount > 0 {
            lowDistanceRepeatCount -= 1
            distance += previousLowDistance
        } else {
            let low = try lowDistances.decodeSymbol(from: &input)
            if low == Self.lowDistanceRepeat {
                lowDistanceRepeatCount = Self.lowDistanceRepeat - 1
                distance += previousLowDistance
            } else {
                distance += low
                previousLowDistance = low
            }
        }
        return distance
    }

    private mutating func insertOldDistance(_ distance: Int) {
        oldDistances[3] = oldDistances[2]
        oldDistances[2] = oldDistances[1]
        oldDistances[1] = oldDistances[0]
        oldDistances[0] = distance
    }

    /// Copies `length` bytes from `distance` back. Like UnRAR, a distance that
    /// reaches before the first byte of this entry (or beyond the window)
    /// produces zeros, so the output never depends on stale window contents.
    private mutating func copy(length: Int, distance: Int) throws {
        guard distance > 0 else { throw RARError.corruptData("zero distance") }
        if UInt64(distance) > produced || distance > window.count {
            for _ in 0..<length {
                window[position] = 0
                position = (position + 1) & mask
            }
        } else {
            var source = (position - distance) & mask
            for _ in 0..<length {
                window[position] = window[source]
                position = (position + 1) & mask
                source = (source + 1) & mask
            }
        }
        produced += UInt64(length)
        pending += length
    }

    // MARK: - Blocks and tables

    /// Returns false at the end of the file ("new file" marker).
    private mutating func readEndOfBlock() throws -> Bool {
        // "1": new table here; "00": end of file; "01": end of file, new
        // table at the start of the next (solid) file.
        if try input.readBits(1) == 1 {
            try readTables()
            return true
        }
        _ = try input.readBits(1)
        return false
    }

    private mutating func readTables() throws {
        try input.alignToByte()
        let header = try input.peekBits(2)
        if header & 0b10 != 0 {
            // PPMd block: phase 4.
            throw RARError.unsupportedCompression(method: method)
        }
        if header & 0b01 == 0 {
            oldTable = [UInt8](repeating: 0, count: Self.tableSize)
        }
        try input.skipBits(2)
        previousLowDistance = 0
        lowDistanceRepeatCount = 0

        var bitLengths = [UInt8](repeating: 0, count: Self.bitLengthCount)
        var index = 0
        while index < Self.bitLengthCount {
            let length = try readBits(4)
            if length == 15 {
                let zeros = try readBits(4)
                if zeros == 0 {
                    bitLengths[index] = 15
                    index += 1
                } else {
                    index = min(index + zeros + 2, Self.bitLengthCount)
                }
            } else {
                bitLengths[index] = UInt8(length)
                index += 1
            }
        }
        let bitLengthTable = try HuffmanTable(codeLengths: bitLengths)

        var table = [UInt8](repeating: 0, count: Self.tableSize)
        index = 0
        while index < Self.tableSize {
            let number = try bitLengthTable.decodeSymbol(from: &input)
            switch number {
            case 0..<16:
                table[index] = UInt8((number + Int(oldTable[index])) & 0xF)
                index += 1
            case 16, 17:
                let count = try number == 16 ? readBits(3) + 3 : readBits(7) + 11
                guard index > 0 else { throw RARError.corruptData("table repeats before first length") }
                let previous = table[index - 1]
                let stop = min(index + count, Self.tableSize)
                while index < stop {
                    table[index] = previous
                    index += 1
                }
            case 18, 19:
                let count = try number == 18 ? readBits(3) + 3 : readBits(7) + 11
                index = min(index + count, Self.tableSize)
            default:
                throw RARError.corruptData("bit length symbol \(number)")
            }
        }

        var start = 0
        func slice(_ count: Int) -> [UInt8] {
            defer { start += count }
            return Array(table[start..<(start + count)])
        }
        literals = try HuffmanTable(codeLengths: slice(Self.literalCount))
        distances = try HuffmanTable(codeLengths: slice(Self.distanceCount))
        lowDistances = try HuffmanTable(codeLengths: slice(Self.lowDistanceCount))
        repeats = try HuffmanTable(codeLengths: slice(Self.repeatCount))
        oldTable = table
    }

    // MARK: - Output

    /// Hands the bytes produced since the last flush to `sink`, never more
    /// than `outputSize` in total.
    private mutating func flush(into sink: ([UInt8]) throws -> Void) throws {
        var count = Int(min(UInt64(pending), outputSize - written))
        pending = 0
        while count > 0 {
            let run = min(count, window.count - flushPosition)
            try sink(Array(window[flushPosition..<(flushPosition + run)]))
            written += UInt64(run)
            flushPosition = (flushPosition + run) & mask
            count -= run
        }
        flushPosition = position
    }
}
