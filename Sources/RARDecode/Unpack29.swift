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
// Ported from UnRAR's unpack30.cpp (Unpack29, ReadTables30, ReadEndOfBlock,
// ReadVMCode, AddVMCode, UnpWriteBuf30, InitFilters30), unpack.cpp
// (UnpInitData, UnpWriteArea, UnpWriteData) and unpackinline.cpp (CopyString,
// InsertOldDist), plus the PPMd paths of unpack30.cpp (the BLOCK_PPM branch
// of Unpack29, the PPM branch of ReadTables30, ReadVMCodePPM). The PPMd
// model itself is in PPMdModel.swift.

import RARCore

/// RAR 2.9/3.x LZ + Huffman and PPMd decoder with RarVM standard filters. One value
/// lives for a whole archive, so solid entries can share its state.
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

    /// UnRAR caps the number of distinct filters and pending filter blocks.
    static let maxFilters = 8192
    /// Retry interval while a pending filter block is not complete yet.
    static let blockedRetry = 0x100

    private var method = 0
    private var input: StreamBitReader
    /// Size of the current entry.
    private var outputSize: UInt64 = 0

    private var window: [UInt8] = []
    var windowCount: Int { window.count }
    private var mask = 0
    private var flushThreshold = 0
    /// Next write position in the window (UnRAR's UnpPtr).
    private var position = 0
    /// Window position of the first byte not yet written (UnRAR's WrPtr).
    private var writePosition = 0
    /// Bytes produced into the window since the start of the solid block.
    private var produced: UInt64 = 0
    /// `produced` at the start of the current entry.
    private var entryStart: UInt64 = 0
    /// `produced` at which the next flush is due.
    private var nextFlush: UInt64 = 0
    /// Bytes counted as written for this entry (UnRAR's WrittenFileSize). It
    /// may pass `outputSize`; the sink never gets more than `outputSize`.
    private var writtenFileSize: UInt64 = 0

    /// Larger than any window, so an unset distance copies zeros.
    private var oldDistances = [Int](repeating: Int(UInt32.max), count: 4)
    private var lastLength = 0
    private var previousLowDistance = 0
    private var lowDistanceRepeatCount = 0
    private var oldTable = [UInt8](repeating: 0, count: tableSize)
    /// Whether the tables are valid for the next solid entry (TablesRead3).
    private var tablesRead = false

    private var literals = HuffmanTable.empty
    private var distances = HuffmanTable.empty
    private var lowDistances = HuffmanTable.empty
    private var repeats = HuffmanTable.empty

    // Filters (UnRAR's Filters30, OldFilterLengths, LastFilter, PrgStack).
    private var filters: [StandardFilter] = []
    private var oldFilterLengths: [UInt32] = []
    private var lastFilter = 0
    private var pendingFilters: [PendingFilter?] = []
    private var vmMemory = [UInt8](repeating: 0, count: RarVM.memorySize + 4)
    /// How often each filter ran; tests use it to prove a fixture filters.
    private(set) var appliedFilters: [StandardFilter: Int] = [:]

    // PPMd (UnRAR's PPM, PPMEscChar, UnpBlockType).
    private var ppm = PPMdModel()
    private var ppmEscape = 2
    private var blockIsPPM = false
    private var ppmMemoryLimit: UInt64 = 0
    var ppmCoverage: PPMdCoverage { ppm.coverage }

    private struct PendingFilter {
        var filter: StandardFilter
        var blockStart: Int
        var blockLength: UInt32
        var nextWindow: Bool
        var registers: [UInt32]
    }

    init() throws {
        input = try StreamBitReader(source: DataSource([]), offset: 0, count: 0)
    }

    /// Decodes one entry. For a solid entry the window, distances, tables
    /// and filter definitions of the previous entry carry over
    /// (UnpInitData with Solid set); otherwise everything starts afresh.
    mutating func decode(
        method: Int, input: StreamBitReader, outputSize: UInt64, dictionarySize: UInt64,
        ppmMemoryLimit: UInt64, solid: Bool, into sink: ([UInt8]) throws -> Void
    ) throws {
        if !solid || window.isEmpty {
            // UnpInitData30(false). Unlike UnRAR, which keeps the PPMd model
            // of the previous file, a non-solid entry starts without one.
            blockIsPPM = false
            ppmEscape = 2
            ppm.discard()
            try allocateWindow(dictionarySize)
            oldDistances = [Int](repeating: Int(UInt32.max), count: 4)
            lastLength = 0
            oldTable = [UInt8](repeating: 0, count: Self.tableSize)
            tablesRead = false
            position = 0
            writePosition = 0
            produced = 0
            filters = []
            oldFilterLengths = []
            lastFilter = 0
        }
        pendingFilters = []
        self.method = method
        self.input = input
        self.outputSize = outputSize
        self.ppmMemoryLimit = ppmMemoryLimit
        writtenFileSize = 0
        entryStart = produced
        nextFlush = produced + UInt64(flushThreshold)
        try run(into: sink)
    }

    private mutating func allocateWindow(_ dictionarySize: UInt64) throws {
        guard dictionarySize <= UInt64(Int.max / 2) else { throw RARError.limitExceeded(.dictionarySize) }
        var size = Self.minimumWindow
        while size < Int(dictionarySize) { size <<= 1 }
        if window.count != size {
            window = [UInt8](repeating: 0, count: size)
        }
        mask = size - 1
        flushThreshold = min(size - Self.matchMargin, 1 << 20)
    }

    private mutating func run(into sink: ([UInt8]) throws -> Void) throws {
        do {
            if input.remainingBits > 0, !tablesRead {
                try readTables()
            } else if blockIsPPM {
                // A solid entry continues an open PPMd block, coder and all.
                ppm.countSolidContinuation()
            }
            try decodeSymbols(into: sink)
        } catch RARError.truncated {
            // The input ran out, which ends the entry as in UnRAR. Whether
            // the output is complete is checked below.
        }
        try writeBuffer(into: sink)
        guard min(writtenFileSize, outputSize) == outputSize else { throw RARError.truncated }
    }

    private mutating func decodeSymbols(into sink: ([UInt8]) throws -> Void) throws {
        // Like UnRAR, read on past the end of the data up to the "new file"
        // marker, which says whether the next solid entry has new tables.
        // Stop once the output is longer than the entry.
        while produced - entryStart <= outputSize {
            if blockIsPPM {
                // UnpReadBuf30 fails once the input was read past its end.
                // Before that, the range coder may still hold symbols.
                if input.overreadBytes > 0 { return }
            } else if input.remainingBits == 0 {
                return
            }
            if produced >= nextFlush {
                try writeBuffer(into: sink)
                let unflushed = (position - writePosition) & mask
                let remaining = unflushed < flushThreshold ? flushThreshold - unflushed : 0
                nextFlush = produced + UInt64(max(remaining, Self.blockedRetry))
            }

            if blockIsPPM {
                if try !decodePPM() { return }
                continue
            }

            let number = try literals.decodeSymbol(from: &input)
            switch number {
            case 0..<256:
                window[position] = UInt8(number)
                position = (position + 1) & mask
                produced += 1

            case 256:
                if try !readEndOfBlock() { return }

            case 257:
                try readFilter()

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
    /// reaches before the first byte of the solid block (of this entry, if it
    /// is not solid) or beyond the window produces zeros, so the output never
    /// depends on stale window contents.
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
        tablesRead = try input.readBits(1) == 0
        return false
    }

    private mutating func readTables() throws {
        try input.alignToByte()
        let header = try input.peekBits(2)
        if header & 0b10 != 0 {
            // A PPMd block; its first byte is also the PPMd flags byte.
            blockIsPPM = true
            try ppm.decodeInit(escapeCharacter: &ppmEscape, memoryLimit: ppmMemoryLimit, input: &input)
            return
        }
        blockIsPPM = false
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
        tablesRead = true
    }


    // MARK: - PPMd

    /// One step of the BLOCK_PPM branch of `Unpack29`: a literal byte or an
    /// escape sequence. Returns false at the end of the file.
    private mutating func decodePPM() throws -> Bool {
        let character = try ppm.decodeChar(&input)
        if character == ppmEscape {
            let code = try ppm.decodeChar(&input)
            ppm.countEscape(code)
            switch code {
            case 0:
                // End of PPMd: tables (LZ or a new PPMd block) follow.
                try readTables()
                return true
            case 2:
                return false
            case 3:
                try readFilterPPM()
                return true
            case 4:
                var distance = 0
                for _ in 0..<3 {
                    distance = distance << 8 + (try ppm.decodeChar(&input))
                }
                let length = try ppm.decodeChar(&input)
                try copy(length: length + 32, distance: distance + 2)
                return true
            case 5:
                let length = try ppm.decodeChar(&input)
                try copy(length: length + 4, distance: 1)
                return true
            default:
                // 1 (and anything else): the escape byte itself.
                break
            }
        }
        window[position] = UInt8(truncatingIfNeeded: character)
        position = (position + 1) & mask
        produced += 1
        return true
    }

    /// `ReadVMCodePPM`: a filter header read through the PPMd model.
    private mutating func readFilterPPM() throws {
        let firstByte = try ppm.decodeChar(&input)
        var length = (firstByte & 7) + 1
        if length == 7 {
            length = try ppm.decodeChar(&input) + 7
        } else if length == 8 {
            let high = try ppm.decodeChar(&input)
            length = high * 256 + (try ppm.decodeChar(&input))
        }
        guard length > 0 else { throw RARError.corruptData("empty filter header") }
        var code: [UInt8] = []
        code.reserveCapacity(length)
        for _ in 0..<length {
            code.append(UInt8(truncatingIfNeeded: try ppm.decodeChar(&input)))
        }
        try addFilter(firstByte: firstByte, code: code)
    }

    // MARK: - Filters

    /// `ReadVMCode`: the filter header that follows symbol 257.
    private mutating func readFilter() throws {
        let firstByte = try readBits(8)
        var length = (firstByte & 7) + 1
        if length == 7 {
            length = try readBits(8) + 7
        } else if length == 8 {
            length = try readBits(16)
        }
        guard length > 0 else { throw RARError.corruptData("empty filter header") }
        var code: [UInt8] = []
        code.reserveCapacity(length)
        for _ in 0..<length {
            code.append(UInt8(try readBits(8)))
        }
        try addFilter(firstByte: firstByte, code: code)
    }

    /// `AddVMCode`: defines or reuses a filter and queues it for a block.
    private mutating func addFilter(firstByte: Int, code: [UInt8]) throws {
        var header = VMBitInput(code)
        var index: Int
        if firstByte & 0x80 != 0 {
            let value = RarVM.readData(&header)
            if value == 0 {
                // InitFilters30(false): forget every filter, pending ones too.
                filters = []
                oldFilterLengths = []
                lastFilter = 0
                pendingFilters = []
                index = 0
            } else {
                index = Int(value) - 1
            }
        } else {
            index = lastFilter
        }
        guard index <= filters.count, index <= oldFilterLengths.count else {
            throw RARError.corruptData("filter index \(index)")
        }
        lastFilter = index
        let isNew = index == filters.count
        if isNew, index > Self.maxFilters { throw RARError.corruptData("too many filters") }

        pendingFilters.removeAll { $0 == nil }
        guard pendingFilters.count <= Self.maxFilters else { throw RARError.corruptData("too many pending filters") }

        var blockStart = RarVM.readData(&header)
        if firstByte & 0x40 != 0 { blockStart &+= 258 }
        if isNew { oldFilterLengths.append(0) }
        let blockLength: UInt32
        if firstByte & 0x20 != 0 {
            blockLength = RarVM.readData(&header)
            oldFilterLengths[index] = blockLength
        } else {
            blockLength = oldFilterLengths[index]
        }
        let unflushedGap = (writePosition - position) & mask
        let nextWindow = writePosition != position && unflushedGap <= Int(blockStart)

        var registers = [UInt32](repeating: 0, count: 7)
        registers[4] = blockLength
        if firstByte & 0x10 != 0 {
            let initMask = header.peek16() >> 9
            header.skip(7)
            for register in 0..<7 where initMask & (1 << register) != 0 {
                registers[register] = RarVM.readData(&header)
            }
        }

        if isNew {
            let size = Int(RarVM.readData(&header))
            guard size > 0, size < 0x10000, header.byteAddress + size <= code.count else {
                throw RARError.corruptData("filter program size \(size)")
            }
            var program: [UInt8] = []
            program.reserveCapacity(size)
            for _ in 0..<size {
                guard !header.overflows(3) else { throw RARError.corruptData("filter program overflow") }
                program.append(UInt8(header.peek16() >> 8))
                header.skip(8)
            }
            switch RarVM.recognise(program) {
            case .standard(let filter): filters.append(filter)
            case .badChecksum: throw RARError.corruptData("filter program checksum")
            // A general RarVM program: UnRAR 7 no longer runs these either.
            case .unknown: throw RARError.unsupportedCompression(method: method)
            }
        }

        pendingFilters.append(PendingFilter(
            filter: filters[index],
            blockStart: (Int(blockStart) + position) & mask,
            blockLength: blockLength,
            nextWindow: nextWindow,
            registers: registers))
    }

    /// Copies `count` window bytes from `start` (wrapping) into VM memory.
    private mutating func loadVMMemory(from start: Int, count: Int) {
        var remaining = min(count, RarVM.memorySize)
        var source = start
        var target = 0
        while remaining > 0 {
            let run = min(remaining, window.count - source)
            vmMemory.replaceSubrange(target..<(target + run), with: window[source..<(source + run)])
            target += run
            remaining -= run
            source = (source + run) & mask
        }
    }

    private mutating func runFilter(_ pending: PendingFilter) -> (offset: Int, count: Int) {
        var registers = pending.registers
        registers[6] = UInt32(truncatingIfNeeded: writtenFileSize)
        appliedFilters[pending.filter, default: 0] += 1
        return RarVM.execute(pending.filter, registers: registers, memory: &vmMemory)
    }

    // MARK: - Output

    /// `UnpWriteBuf30`: writes the window up to `position`, running each
    /// pending filter over its block once the block is complete. Stops in
    /// front of a block that is not complete yet. The window itself stays
    /// unfiltered, because later matches refer to it.
    private mutating func writeBuffer(into sink: ([UInt8]) throws -> Void) throws {
        var border = writePosition
        var writeSize = (position - border) & mask
        var index = 0
        while index < pendingFilters.count {
            defer { index += 1 }
            guard let pending = pendingFilters[index] else { continue }
            if pending.nextWindow {
                pendingFilters[index]?.nextWindow = false
                continue
            }
            let blockStart = pending.blockStart
            guard (blockStart - border) & mask < writeSize else { continue }
            if border != blockStart {
                try writeArea(from: border, to: blockStart, into: sink)
                border = blockStart
                writeSize = (position - border) & mask
            }
            guard UInt64(pending.blockLength) <= UInt64(writeSize) else {
                // The block is not complete yet: write up to it and retry later.
                for later in index..<pendingFilters.count {
                    pendingFilters[later]?.nextWindow = false
                }
                writePosition = border
                return
            }
            let blockLength = Int(pending.blockLength)
            let blockEnd = (blockStart + blockLength) & mask
            loadVMMemory(from: blockStart, count: blockLength)
            var (offset, count) = runFilter(pending)
            pendingFilters[index] = nil
            // Further filters on the same block run on the filtered data.
            while index + 1 < pendingFilters.count, let next = pendingFilters[index + 1],
                  next.blockStart == blockStart, UInt64(next.blockLength) == UInt64(count), !next.nextWindow {
                if offset != 0 {
                    let filtered = Array(vmMemory[offset..<(offset + count)])
                    vmMemory.replaceSubrange(0..<count, with: filtered)
                }
                (offset, count) = runFilter(next)
                index += 1
                pendingFilters[index] = nil
            }
            try writeData(Array(vmMemory[offset..<(offset + count)]), into: sink)
            border = blockEnd
            writeSize = (position - border) & mask
        }
        try writeArea(from: border, to: position, into: sink)
        writePosition = position
    }

    /// `UnpWriteArea`: the window from `start` to `end`, wrapping.
    private mutating func writeArea(from start: Int, to end: Int, into sink: ([UInt8]) throws -> Void) throws {
        if end < start {
            try writeData(Array(window[start..<window.count]), into: sink)
            try writeData(Array(window[0..<end]), into: sink)
        } else if end > start {
            try writeData(Array(window[start..<end]), into: sink)
        }
    }

    /// `UnpWriteData`: never hands more than `outputSize` bytes to the sink.
    private mutating func writeData(_ bytes: [UInt8], into sink: ([UInt8]) throws -> Void) throws {
        guard writtenFileSize < outputSize else { return }
        let left = outputSize - writtenFileSize
        if UInt64(bytes.count) > left {
            try sink(Array(bytes.prefix(Int(left))))
        } else if !bytes.isEmpty {
            try sink(bytes)
        }
        writtenFileSize += UInt64(bytes.count)
    }
}
