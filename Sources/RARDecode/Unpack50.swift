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
// Ported from UnRAR's unpack50.cpp (Unpack5, ReadBlockHeader, ReadTables,
// ReadFilter, AddFilter, UnpWriteBuf), unpackinline.cpp (SlotToLength,
// CopyString, InsertOldDist) and unpack.cpp (Init, UnpInitData).

import RARCore

/// Which unpack50 paths a session went through; tests use it to prove that
/// a fixture covers what it is meant to cover.
public struct RAR5Coverage: Equatable, Sendable {
    /// Block headers read.
    public var blocks = 0
    /// Block headers that carried new Huffman tables.
    public var blocksWithTables = 0
    /// Filters applied, by type.
    public var filters: [RAR5Filter: Int] = [:]
    /// Symbol 257: repeat the last match.
    public var repeatLast = 0
    /// Symbols 258 to 261: a match with one of the four old distances.
    public var oldDistances = 0
    /// Matches whose length got the distance bonus (distance above 0x100).
    public var lengthBonus = 0
    /// Distances with more than 4 extra bits (read in two parts plus the
    /// low-distance table).
    public var longDistances = 0
    /// Times the write position wrapped around the window.
    public var windowWraps = 0
    /// Matches that reached before the data and produced zeros.
    public var zeroFills = 0
    /// Entries that continued a solid stream.
    public var solidContinuations = 0
    public init() {}
}

struct Unpack50 {
    static let literalCount = 306
    static let distanceCount = 64
    /// RAR 7.0 (`ExtraDist`): distances up to 1 TB.
    static let extendedDistanceCount = 80
    static let lowDistanceCount = 16
    static let repeatCount = 44
    static let bitLengthCount = 20
    /// `Unpack::Init`: at least twice the largest filter block.
    static let minimumWindow = 0x40000
    /// `MAX_INC_LZ_MATCH`: the longest match, bonus included.
    static let maxMatch = 0x1004
    static let maxWrite = 0x400000
    static let maxFilterBlock = 0x400000
    static let maxFilters = 8192

    private var input: StreamBitReader
    private var extraDistance = false
    private var outputSize: UInt64 = 0

    private var window: [UInt8] = []
    var windowCount: Int { window.count }
    /// UnRAR's MaxWinSize; `window` may be larger when reused.
    private var windowSize = 0
    /// UnpPtr.
    private var position = 0
    /// WrPtr: first window byte not written yet.
    private var writePosition = 0
    /// WriteBorder: flush before `position` gets within a match of it.
    private var writeBorder = 0
    /// Bytes produced since the start of the solid block. A distance beyond
    /// it produces zeros (UnRAR's FirstWinDone rule).
    private var produced: UInt64 = 0
    private var entryStart: UInt64 = 0
    /// WrittenFileSize; may pass `outputSize`, the sink never does.
    private var writtenFileSize: UInt64 = 0

    private var oldDistances = [Int](repeating: Int.max, count: 4)
    private var lastLength = 0

    private var tablesRead = false
    private var literals = HuffmanTable.empty
    private var distances = HuffmanTable.empty
    private var lowDistances = HuffmanTable.empty
    private var repeats = HuffmanTable.empty

    /// Bit position where the current block ends.
    private var blockEnd: UInt64 = 0
    private var lastBlock = false

    private struct Filter {
        var type: Int
        var channels: Int
        var blockStart: Int
        var blockLength: Int
        var nextWindow: Bool
        /// Applied (UnRAR sets its type to FILTER_NONE).
        var done = false
    }
    private var filters: [Filter] = []

    private(set) var coverage = RAR5Coverage()

    init() throws {
        input = try StreamBitReader(source: DataSource([]), offset: 0, count: 0)
    }

    /// Decodes one entry. A solid entry keeps the window, distances and
    /// tables of the entry before it (UnpInitData with Solid set).
    mutating func decode(
        input: StreamBitReader, outputSize: UInt64, dictionarySize: UInt64,
        extraDistance: Bool, solid: Bool, into sink: ([UInt8]) throws -> Void
    ) throws {
        let size = max(dictionarySize, UInt64(Self.minimumWindow))
        guard size <= UInt64(Int.max / 2) else { throw RARError.limitExceeded(.dictionarySize) }
        if !solid || window.isEmpty {
            // Unpack::Init: a non-solid entry uses its own window size and
            // reuses a larger allocation.
            if window.count < Int(size) {
                window = [UInt8](repeating: 0, count: Int(size))
            }
            windowSize = Int(size)
            oldDistances = [Int](repeating: Int.max, count: 4)
            lastLength = 0
            position = 0
            writePosition = 0
            writeBorder = min(windowSize, Self.maxWrite)
            produced = 0
            tablesRead = false
            literals = .empty
            distances = .empty
            lowDistances = .empty
            repeats = .empty
        } else {
            // rar never grows the window inside a solid stream; UnRAR
            // refuses it (bad_alloc).
            guard Int(size) <= window.count else { throw RARError.corruptData("solid entry needs a larger window") }
            coverage.solidContinuations += 1
        }
        filters = []
        self.input = input
        self.extraDistance = extraDistance
        self.outputSize = outputSize
        writtenFileSize = 0
        entryStart = produced
        blockEnd = 0
        lastBlock = false

        do {
            try readBlockHeader()
            guard tablesRead else { throw RARError.corruptData("block without tables") }
            if try decodeSymbols(into: sink) {
                try writeBuffer(into: sink)
            }
        } catch RARError.truncated {
            // The input ran out; whether the output is complete is checked below.
            try writeBuffer(into: sink)
        }
        guard min(writtenFileSize, outputSize) == outputSize else { throw RARError.truncated }
    }

    /// The main loop of `Unpack5`. Returns false when it stopped because more
    /// than the entry was written (UnRAR then skips the final write).
    private mutating func decodeSymbols(into sink: ([UInt8]) throws -> Void) throws -> Bool {
        var previousPosition = position
        while produced - entryStart <= outputSize {
            if position < previousPosition { coverage.windowWraps += 1 }
            previousPosition = position

            if input.bitPosition >= blockEnd {
                // Several headers in a row for blocks that hold only tables.
                while input.bitPosition >= blockEnd {
                    if lastBlock { return true }
                    try readBlockHeader()
                }
            }

            if gap(writeBorder, position) <= Self.maxMatch && writeBorder != position {
                try writeBuffer(into: sink)
                if writtenFileSize > outputSize { return false }
            }

            let mainSlot = try literals.decodeSymbol(from: &input)
            switch mainSlot {
            case 0..<256:
                window[position] = UInt8(mainSlot)
                position += 1
                if position == windowSize { position = 0 }
                produced += 1

            case 256:
                try readFilter(into: sink)

            case 257:
                coverage.repeatLast += 1
                if lastLength != 0 { copy(length: lastLength, distance: oldDistances[0]) }

            case 258..<262:
                coverage.oldDistances += 1
                let index = mainSlot - 258
                let distance = oldDistances[index]
                for slot in stride(from: index, to: 0, by: -1) {
                    oldDistances[slot] = oldDistances[slot - 1]
                }
                oldDistances[0] = distance
                let lengthSlot = try repeats.decodeSymbol(from: &input)
                let length = try slotToLength(lengthSlot)
                lastLength = length
                copy(length: length, distance: distance)

            default:
                var length = try slotToLength(mainSlot - 262)
                let distance = try readDistance()
                if distance > 0x100 {
                    coverage.lengthBonus += 1
                    length += 1
                    if distance > 0x2000 {
                        length += 1
                        if distance > 0x40000 { length += 1 }
                    }
                }
                oldDistances[3] = oldDistances[2]
                oldDistances[2] = oldDistances[1]
                oldDistances[1] = oldDistances[0]
                oldDistances[0] = distance
                lastLength = length
                copy(length: length, distance: distance)
            }
        }
        return true
    }

    // MARK: - Symbols

    private mutating func readBits(_ count: Int) throws -> Int {
        Int(try input.readBits(count))
    }

    /// `SlotToLength`: lengths 2 to 4097.
    private mutating func slotToLength(_ slot: Int) throws -> Int {
        guard slot >= 0, slot < Self.repeatCount else { throw RARError.corruptData("length slot \(slot)") }
        if slot < 8 { return 2 + slot }
        let bits = slot / 4 - 1
        return 2 + ((4 | (slot & 3)) << bits) + (try readBits(bits))
    }

    private mutating func readDistance() throws -> Int {
        let slot = try distances.decodeSymbol(from: &input)
        if slot < 4 { return 1 + slot }
        let bits = slot / 2 - 1
        var distance = 1 + ((2 | (slot & 1)) << bits)
        if bits < 4 { return distance + (try readBits(bits)) }
        if bits > 4 {
            // Up to 35 bits (RAR 7.0), more than one read takes.
            coverage.longDistances += 1
            let high = bits - 4
            if high > 16 {
                distance += (try readBits(high - 16)) << 20
                distance += (try readBits(16)) << 4
            } else {
                distance += (try readBits(high)) << 4
            }
        }
        return distance + (try lowDistances.decodeSymbol(from: &input))
    }

    /// `CopyString`. A distance that reaches before the solid block (or
    /// beyond the window) produces zeros, so the output never depends on
    /// stale window contents.
    private mutating func copy(length: Int, distance: Int) {
        defer { produced += UInt64(length) }
        if distance > windowSize || UInt64(distance) > produced {
            coverage.zeroFills += 1
            for _ in 0..<length {
                window[position] = 0
                position += 1
                if position == windowSize { position = 0 }
            }
            return
        }
        var source = position - distance
        if source < 0 { source += windowSize }
        if source + length <= windowSize && position + length <= windowSize {
            // No wrap: overlapping copies must go byte by byte anyway.
            for offset in 0..<length {
                window[position + offset] = window[source + offset]
            }
            position += length
            if position == windowSize { position = 0 }
            return
        }
        for _ in 0..<length {
            window[position] = window[source]
            source += 1
            if source == windowSize { source = 0 }
            position += 1
            if position == windowSize { position = 0 }
        }
    }

    /// `WrapDown(to - from)`: distance from `from` forward to `to`.
    private func gap(_ to: Int, _ from: Int) -> Int {
        let difference = to - from
        return difference < 0 ? difference + windowSize : difference
    }

    // MARK: - Blocks and tables

    /// `ReadBlockHeader`: flags, checksum and a 1- to 3-byte block size,
    /// followed by the tables if the flags say so.
    private mutating func readBlockHeader() throws {
        try input.alignToByte()
        let flags = try readBits(8)
        let byteCount = (flags >> 3) & 3 + 1
        guard byteCount < 4 else { throw RARError.corruptData("block size of 4 bytes") }
        let checksum = try readBits(8)
        var blockSize = 0
        for index in 0..<byteCount {
            blockSize |= (try readBits(8)) << (8 * index)
        }
        let expected = (0x5A ^ flags ^ blockSize ^ (blockSize >> 8) ^ (blockSize >> 16)) & 0xFF
        guard checksum == expected else { throw RARError.corruptData("block header checksum") }
        // The block ends `BlockBitSize` bits into its last byte. A block of
        // size 0 ends where it starts.
        let start = input.bitPosition
        blockEnd = start + UInt64(blockSize) * 8 - 8 + UInt64(flags & 7 + 1)
        lastBlock = flags & 0x40 != 0
        coverage.blocks += 1
        if flags & 0x80 != 0 {
            coverage.blocksWithTables += 1
            try readTables()
        }
    }

    /// `ReadTables`, for a block header that carries tables.
    private mutating func readTables() throws {
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

        let distanceCount = extraDistance ? Self.extendedDistanceCount : Self.distanceCount
        let tableSize = Self.literalCount + distanceCount + Self.lowDistanceCount + Self.repeatCount
        var table = [UInt8](repeating: 0, count: tableSize)
        index = 0
        while index < tableSize {
            let number = try bitLengthTable.decodeSymbol(from: &input)
            switch number {
            case 0..<16:
                table[index] = UInt8(number)
                index += 1
            case 16, 17:
                let count = try number == 16 ? readBits(3) + 3 : readBits(7) + 11
                guard index > 0 else { throw RARError.corruptData("table repeats before first length") }
                let previous = table[index - 1]
                let stop = min(index + count, tableSize)
                while index < stop {
                    table[index] = previous
                    index += 1
                }
            default:
                let count = try number == 18 ? readBits(3) + 3 : readBits(7) + 11
                index = min(index + count, tableSize)
            }
        }
        tablesRead = true

        var start = 0
        func slice(_ count: Int) -> [UInt8] {
            defer { start += count }
            return Array(table[start..<(start + count)])
        }
        literals = try HuffmanTable(codeLengths: slice(Self.literalCount))
        distances = try HuffmanTable(codeLengths: slice(distanceCount))
        lowDistances = try HuffmanTable(codeLengths: slice(Self.lowDistanceCount))
        repeats = try HuffmanTable(codeLengths: slice(Self.repeatCount))
    }

    // MARK: - Filters

    /// `ReadFilterData`: 1 to 4 bytes, little-endian.
    private mutating func readFilterData() throws -> Int {
        let byteCount = try readBits(2) + 1
        var value = 0
        for index in 0..<byteCount {
            value |= (try readBits(8)) << (8 * index)
        }
        return value
    }

    /// `ReadFilter` and `AddFilter`.
    private mutating func readFilter(into sink: ([UInt8]) throws -> Void) throws {
        let blockStart = try readFilterData()
        var blockLength = try readFilterData()
        if blockLength > Self.maxFilterBlock { blockLength = 0 }
        let type = try readBits(3)
        var channels = 0
        if type == RAR5Filter.delta.rawValue {
            channels = try readBits(5) + 1
        }

        if filters.count >= Self.maxFilters {
            try writeBuffer(into: sink)
            // Still too many: drop them all rather than use more memory.
            if filters.count >= Self.maxFilters { filters = [] }
        }
        // A start that points back into data not written yet (the window
        // wrapped) belongs to the next pass over the window.
        let nextWindow = writePosition != position && gap(writePosition, position) <= blockStart
        filters.append(Filter(type: type, channels: channels,
                              blockStart: (blockStart + position) % windowSize,
                              blockLength: blockLength, nextWindow: nextWindow))
    }

    // MARK: - Output

    /// `UnpWriteBuf`: writes the window up to `position`, running each
    /// filter over its block once the block is complete. Stops in front of
    /// a block that is not complete yet. The window itself stays
    /// unfiltered, because later matches refer to it.
    private mutating func writeBuffer(into sink: ([UInt8]) throws -> Void) throws {
        var border = writePosition
        let fullWriteSize = gap(position, border)
        var writeSizeLeft = fullWriteSize
        var allProcessed = true
        for index in filters.indices {
            let filter = filters[index]
            if filter.done { continue }
            if filter.nextWindow {
                if gap(filter.blockStart, writePosition) <= fullWriteSize {
                    filters[index].nextWindow = false
                }
                continue
            }
            guard gap(filter.blockStart, border) < writeSizeLeft else { continue }
            if border != filter.blockStart {
                try writeArea(from: border, to: filter.blockStart, into: sink)
                border = filter.blockStart
                writeSizeLeft = gap(position, border)
            }
            guard filter.blockLength <= writeSizeLeft else {
                // The block is not complete yet: write up to it, retry later.
                writePosition = border
                for later in index..<filters.count where !filters[later].done {
                    filters[later].nextWindow = false
                }
                allProcessed = false
                break
            }
            // A zero length marks an invalid filter; UnRAR leaves it queued.
            guard filter.blockLength > 0 else { continue }
            let blockEnd = (filter.blockStart + filter.blockLength) % windowSize
            var data: [UInt8]
            if filter.blockStart < blockEnd || blockEnd == 0 {
                data = Array(window[filter.blockStart..<(filter.blockStart + filter.blockLength)])
            } else {
                data = Array(window[filter.blockStart..<windowSize])
                data += window[0..<blockEnd]
            }
            guard let type = RAR5Filter(rawValue: filter.type) else {
                throw RARError.corruptData("filter type \(filter.type)")
            }
            data = RAR5Filters.apply(type, channels: filter.channels, fileOffset: writtenFileSize, to: data)
            coverage.filters[type, default: 0] += 1
            filters[index].done = true
            try writeData(data, into: sink)
            border = blockEnd
            writeSizeLeft = gap(position, border)
        }
        filters.removeAll { $0.done }

        if allProcessed {
            try writeArea(from: border, to: position, into: sink)
            writePosition = position
        }
        // Write in steps of at most `maxWrite`, or up to the unwritten data.
        writeBorder = position + min(windowSize, Self.maxWrite)
        if writeBorder >= windowSize { writeBorder -= windowSize }
        if writeBorder == position
            || writePosition != position && gap(writePosition, position) < gap(writeBorder, position) {
            writeBorder = writePosition
        }
    }

    /// `UnpWriteArea`: the window from `start` to `end`, wrapping.
    private mutating func writeArea(from start: Int, to end: Int, into sink: ([UInt8]) throws -> Void) throws {
        if end < start {
            try writeData(Array(window[start..<windowSize]), into: sink)
            try writeData(Array(window[0..<end]), into: sink)
        } else if end > start {
            try writeData(Array(window[start..<end]), into: sink)
        }
    }

    /// `UnpWriteData`: never hands more than `outputSize` bytes to the sink.
    /// Unlike UnRAR, filtered blocks are capped too.
    private mutating func writeData(_ bytes: [UInt8], into sink: ([UInt8]) throws -> Void) throws {
        guard writtenFileSize < outputSize else {
            writtenFileSize += UInt64(bytes.count)
            return
        }
        let left = outputSize - writtenFileSize
        if UInt64(bytes.count) > left {
            try sink(Array(bytes.prefix(Int(left))))
        } else if !bytes.isEmpty {
            try sink(bytes)
        }
        writtenFileSize += UInt64(bytes.count)
    }
}
