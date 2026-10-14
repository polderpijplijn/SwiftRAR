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
// Ported from UnRAR's model.cpp and coder.cpp (PPMd variant H by Dmitry
// Shkarin, public domain, and the carryless range coder by Dmitry
// Subbotin, as adapted by UnRAR).

import RARCore

/// What a PPMd decode run went through; tests use it to prove that a
/// fixture covers a path.
public struct PPMdCoverage: Equatable, Sendable {
    /// PPMd block headers that started a new model / continued the old one.
    public var resets = 0
    public var continuations = 0
    /// Escape codes after the escape character (0: back to LZ, 1: the
    /// escape byte itself, 2: end of file, 3: filter, 4: match, 5: RLE).
    public var escapes: [Int: Int] = [:]
    /// Model restarts because its memory ran out (`RESTART_MODEL`).
    public var restarts = 0
    public var rescales = 0
    public var glueRuns = 0
    /// Allocations taken from the end of the text area (`AllocUnitsRare`).
    public var textAreaAllocations = 0
    /// Entries in a solid block that started inside an open PPMd block.
    public var solidContinuations = 0
}

/// SEE context for PPM contexts with masked symbols (RARPPM_SEE2_CONTEXT).
private struct SEE2Context {
    var summ: UInt16 = 0
    var shift: UInt8 = 0
    var count: UInt8 = 0

    init() {}

    init(_ initial: Int) {
        shift = UInt8(PPMdModel.periodBits - 4)
        summ = UInt16(truncatingIfNeeded: initial << Int(shift))
        count = 4
    }

    /// `getMean`. UnRAR's GET_SHORT16 is an unsigned 16-bit cast.
    mutating func mean() -> UInt32 {
        let value = summ >> UInt16(shift)
        summ = summ &- value
        return UInt32(value) + (value == 0 ? 1 : 0)
    }

    mutating func update() {
        if Int(shift) < PPMdModel.periodBits {
            count &-= 1
            if count == 0 {
                summ = summ &+ summ
                count = UInt8(truncatingIfNeeded: 3 << Int(shift))
                shift += 1
            }
        }
    }
}

/// PPMd variant H as used by RAR 3.x (ModelPPM plus RangeCoder).
///
/// Contexts and states live in a `PPMdHeap`, addressed by offset, in the
/// original 12-byte layout:
/// - context: NumStats u16 @0, SummFreq u16 @2, Stats u32 @4, Suffix u32 @8;
///   a context with one state keeps it inline at @2 (OneState);
/// - state: Symbol @0, Freq @1, Successor u32 @2.
struct PPMdModel {
    static let intBits = 7, periodBits = 7, totalBits = intBits + periodBits
    static let interval = 1 << intBits, binScale = 1 << totalBits, maxFrequency = 124
    static let maxOrder = 64
    static let top: UInt32 = 1 << 24, bottom: UInt32 = 1 << 15
    static let stateSize = 6
    static let expEscape: [Int] = [25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2]
    static let initBinEscape: [Int] = [0x3CDD, 0x1F3F, 0x59BF, 0x48F3, 0x64A1, 0x5ABC, 0x6632, 0x6051]

    private var heap = PPMdHeap()
    private var see2 = [SEE2Context](repeating: SEE2Context(), count: 25 * 16)
    /// Index of DummySEE2Cont, just past the 25 x 16 table.
    private static let dummySEE2 = 25 * 16
    private var dummy = SEE2Context()

    private var minContext = 0, maxContext = 0
    private var foundState = 0
    private var numMasked = 0, initEscape = 0, orderFall = 0, order = 0
    private var runLength: Int32 = 0, initRunLength: Int32 = 0
    private var charMask = [UInt8](repeating: 0, count: 256)
    private var ns2Index = [Int](repeating: 0, count: 256)
    private var ns2BSIndex = [Int](repeating: 0, count: 256)
    private var hb2Flag = [Int](repeating: 0, count: 256)
    private var escapeCount: UInt8 = 0
    private var previousSuccess = 0
    private var hiBitsFlag = 0
    private var binSumm = [UInt16](repeating: 0, count: 128 * 64)

    // Range coder.
    private var low: UInt32 = 0, code: UInt32 = 0, range: UInt32 = 0
    private var lowCount: UInt32 = 0, highCount: UInt32 = 0, scale: UInt32 = 0

    private(set) var coverage = PPMdCoverage()

    /// Whether a model exists that a block without the reset flag may continue.
    var hasModel: Bool { heap.allocatorSize != 0 }

    // MARK: - Fields

    @inline(__always) private func numStats(_ context: Int) throws -> Int { try heap.u16(context) }
    @inline(__always) private mutating func setNumStats(_ context: Int, _ value: Int) throws { try heap.setU16(context, value) }
    @inline(__always) private func summFreq(_ context: Int) throws -> Int { try heap.u16(context + 2) }
    @inline(__always) private mutating func setSummFreq(_ context: Int, _ value: Int) throws { try heap.setU16(context + 2, value) }
    @inline(__always) private func stats(_ context: Int) throws -> Int { try heap.u32(context + 4) }
    @inline(__always) private mutating func setStats(_ context: Int, _ value: Int) throws { try heap.setU32(context + 4, value) }
    @inline(__always) private func suffix(_ context: Int) throws -> Int { try heap.u32(context + 8) }
    @inline(__always) private mutating func setSuffix(_ context: Int, _ value: Int) throws { try heap.setU32(context + 8, value) }
    @inline(__always) private func oneState(_ context: Int) -> Int { context + 2 }

    @inline(__always) private func symbol(_ state: Int) throws -> Int { try heap.byte(state) }
    @inline(__always) private mutating func setSymbol(_ state: Int, _ value: Int) throws { try heap.setByte(state, value) }
    @inline(__always) private func freq(_ state: Int) throws -> Int { try heap.byte(state + 1) }
    @inline(__always) private mutating func setFreq(_ state: Int, _ value: Int) throws { try heap.setByte(state + 1, value) }
    @inline(__always) private func successor(_ state: Int) throws -> Int { try heap.u32(state + 2) }
    @inline(__always) private mutating func setSuccessor(_ state: Int, _ value: Int) throws { try heap.setU32(state + 2, value) }

    private mutating func copyState(from source: Int, to target: Int) throws {
        try heap.copyBytes(from: source, to: target, count: Self.stateSize)
    }

    private mutating func swapStates(_ a: Int, _ b: Int) throws {
        let (symbolA, freqA, successorA) = (try symbol(a), try freq(a), try successor(a))
        try copyState(from: b, to: a)
        try setSymbol(b, symbolA)
        try setFreq(b, freqA)
        try setSuccessor(b, successorA)
    }

    /// The state for `wanted` in the stats of `context` (which has more
    /// than one state). UnRAR relies on it being there; we stop at NumStats.
    private func findState(in context: Int, symbol wanted: Int) throws -> Int {
        let count = try numStats(context)
        var state = try stats(context)
        for _ in 0..<count {
            if try symbol(state) == wanted { return state }
            state += Self.stateSize
        }
        throw RARError.corruptData("PPMd symbol missing from context")
    }

    // MARK: - Range coder

    private mutating func normalize(_ input: inout StreamBitReader) throws {
        while true {
            if low ^ (low &+ range) < Self.top {
            } else if range < Self.bottom {
                range = (0 &- low) & (Self.bottom - 1)
            } else {
                return
            }
            code = code << 8 | UInt32(try input.readByte())
            range <<= 8
            low <<= 8
        }
    }

    /// `GetCurrentCount`, as the C++ `int` result.
    private mutating func currentCount() throws -> Int {
        guard scale != 0 else { throw RARError.corruptData("PPMd zero scale") }
        range /= scale
        guard range != 0 else { throw RARError.corruptData("PPMd zero range") }
        return Int(Int32(bitPattern: (code &- low) / range))
    }

    private mutating func currentShiftCount(_ shift: Int) throws -> UInt32 {
        range >>= UInt32(shift)
        guard range != 0 else { throw RARError.corruptData("PPMd zero range") }
        return (code &- low) / range
    }

    private mutating func decodeRange() {
        low = low &+ range &* lowCount
        range = range &* (highCount &- lowCount)
    }

    // MARK: - Model setup

    private mutating func restartModel() throws {
        charMask = [UInt8](repeating: 0, count: 256)
        heap.reset()
        initRunLength = -Int32(min(order, 12)) - 1
        let root = try heap.allocContext()
        guard root != 0 else { throw RARError.corruptData("PPMd model memory") }
        minContext = root
        maxContext = root
        try setSuffix(root, 0)
        orderFall = order
        try setNumStats(root, 256)
        try setSummFreq(root, 257)
        let rootStats = try heap.allocUnits(256 / 2)
        guard rootStats != 0 else { throw RARError.corruptData("PPMd model memory") }
        try setStats(root, rootStats)
        foundState = rootStats
        runLength = initRunLength
        previousSuccess = 0
        for index in 0..<256 {
            let state = rootStats + index * Self.stateSize
            try setSymbol(state, index)
            try setFreq(state, 1)
            try setSuccessor(state, 0)
        }
        for i in 0..<128 {
            for k in 0..<8 {
                for m in stride(from: 0, to: 64, by: 8) {
                    binSumm[i * 64 + k + m] = UInt16(Self.binScale - Self.initBinEscape[k] / (i + 2))
                }
            }
        }
        for i in 0..<25 {
            for k in 0..<16 {
                see2[i * 16 + k] = SEE2Context(5 * i + 10)
            }
        }
    }

    private mutating func startModel(order: Int) throws {
        escapeCount = 1
        self.order = order
        try restartModel()
        ns2BSIndex[0] = 0
        ns2BSIndex[1] = 2
        for i in 2..<11 { ns2BSIndex[i] = 4 }
        for i in 11..<256 { ns2BSIndex[i] = 6 }
        for i in 0..<3 { ns2Index[i] = i }
        var m = 3, k = 1, step = 1
        for i in 3..<256 {
            ns2Index[i] = m
            k -= 1
            if k == 0 {
                step += 1
                k = step
                m += 1
            }
        }
        for i in 0..<256 { hb2Flag[i] = i < 0x40 ? 0 : 0x08 }
        dummy.shift = UInt8(Self.periodBits)
    }

    /// `DecodeInit`: reads the PPMd block header and starts the range coder.
    mutating func decodeInit(
        escapeCharacter: inout Int, memoryLimit: UInt64, input: inout StreamBitReader
    ) throws {
        var maxOrder = Int(try input.readByte())
        let reset = maxOrder & 0x20 != 0
        var megabytes = 0
        if reset {
            megabytes = Int(try input.readByte()) + 1
            guard UInt64(megabytes) << 20 <= memoryLimit else { throw RARError.limitExceeded(.ppmdMemory) }
        } else if !hasModel {
            throw RARError.corruptData("PPMd block continues a model that does not exist")
        }
        if maxOrder & 0x40 != 0 {
            escapeCharacter = Int(try input.readByte())
        }
        low = 0
        code = 0
        range = 0xFFFF_FFFF
        for _ in 0..<4 {
            code = code << 8 | UInt32(try input.readByte())
        }
        if reset {
            maxOrder = (maxOrder & 0x1F) + 1
            if maxOrder > 16 {
                maxOrder = 16 + (maxOrder - 16) * 3
            }
            if maxOrder == 1 {
                heap.stop()
                throw RARError.corruptData("PPMd order 1")
            }
            heap.start(megabytes: megabytes)
            try startModel(order: maxOrder)
            coverage.resets += 1
        } else {
            coverage.continuations += 1
        }
        guard minContext != 0 else { throw RARError.corruptData("PPMd model missing") }
    }

    /// Drops the model, as a non-solid entry starts without one.
    mutating func discard() {
        heap.stop()
        minContext = 0
        maxContext = 0
        foundState = 0
    }

    mutating func countEscape(_ code: Int) {
        coverage.escapes[code, default: 0] += 1
    }

    mutating func countSolidContinuation() {
        coverage.solidContinuations += 1
    }

    // MARK: - Decoding

    private func isContext(_ reference: Int) -> Bool {
        reference > heap.pText && reference <= heap.heapEnd
    }

    /// `DecodeChar`. Throws where UnRAR returns -1.
    mutating func decodeChar(_ input: inout StreamBitReader) throws -> Int {
        guard isContext(minContext) else { throw RARError.corruptData("PPMd context") }
        if try numStats(minContext) != 1 {
            guard isContext(try stats(minContext)) else { throw RARError.corruptData("PPMd stats") }
            guard try decodeSymbol1() else { throw RARError.corruptData("PPMd symbol") }
        } else {
            try decodeBinSymbol()
        }
        decodeRange()
        while foundState == 0 {
            try normalize(&input)
            var steps = 0
            repeat {
                orderFall += 1
                minContext = try suffix(minContext)
                guard isContext(minContext) else { throw RARError.corruptData("PPMd suffix") }
                steps += 1
                guard steps <= Self.maxOrder + 1 else { throw RARError.corruptData("PPMd suffix chain") }
            } while try numStats(minContext) == numMasked
            guard try decodeSymbol2() else { throw RARError.corruptData("PPMd symbol") }
            decodeRange()
        }
        let result = try symbol(foundState)
        let found = try successor(foundState)
        if orderFall == 0, found > heap.pText {
            minContext = found
            maxContext = found
        } else {
            try updateModel()
            if escapeCount == 0 {
                escapeCount = 1
                charMask = [UInt8](repeating: 0, count: 256)
            }
        }
        try normalize(&input)
        coverage.glueRuns = heap.glueRuns
        coverage.textAreaAllocations = heap.textAreaAllocations
        return result
    }

    private mutating func decodeBinSymbol() throws {
        let state = oneState(minContext)
        hiBitsFlag = hb2Flag[try symbol(foundState)]
        let stateFreq = try freq(state)
        let suffixStats = try numStats(try suffix(minContext))
        guard stateFreq >= 1, stateFreq <= 128, suffixStats >= 1, suffixStats <= 256 else {
            throw RARError.corruptData("PPMd binary context")
        }
        let index = (stateFreq - 1) * 64 + previousSuccess + ns2BSIndex[suffixStats - 1]
            + hiBitsFlag + 2 * hb2Flag[try symbol(state)] + Int((runLength >> 26) & 0x20)
        let bs = Int(binSumm[index])
        let mean = (bs + (1 << (Self.periodBits - 2))) >> Self.periodBits
        if try currentShiftCount(Self.totalBits) < UInt32(bs) {
            foundState = state
            try setFreq(state, stateFreq + (stateFreq < 128 ? 1 : 0))
            lowCount = 0
            highCount = UInt32(bs)
            binSumm[index] = UInt16(truncatingIfNeeded: bs + Self.interval - mean)
            previousSuccess = 1
            runLength &+= 1
        } else {
            lowCount = UInt32(bs)
            let updated = UInt16(truncatingIfNeeded: bs - mean)
            binSumm[index] = updated
            highCount = UInt32(Self.binScale)
            guard Int(updated >> 10) < Self.expEscape.count else { throw RARError.corruptData("PPMd binary context") }
            initEscape = Self.expEscape[Int(updated >> 10)]
            numMasked = 1
            charMask[try symbol(state)] = escapeCount
            previousSuccess = 0
            foundState = 0
        }
    }

    private mutating func decodeSymbol1() throws -> Bool {
        let context = minContext
        scale = UInt32(try summFreq(context))
        var state = try stats(context)
        let count = try currentCount()
        if count >= Int(scale) { return false }
        var hiCount = try freq(state)
        if count < hiCount {
            highCount = UInt32(hiCount)
            previousSuccess = 2 * hiCount > Int(scale) ? 1 : 0
            runLength &+= Int32(previousSuccess)
            foundState = state
            hiCount += 4
            try setFreq(state, hiCount)
            try setSummFreq(context, try summFreq(context) + 4)
            if hiCount > Self.maxFrequency {
                try rescale(context)
            }
            lowCount = 0
            return true
        } else if foundState == 0 {
            return false
        }
        previousSuccess = 0
        let stateCount = try numStats(context)
        guard stateCount >= 2 else { return false }
        var i = stateCount - 1
        while true {
            state += Self.stateSize
            hiCount += try freq(state)
            if hiCount > count { break }
            i -= 1
            if i == 0 {
                hiBitsFlag = hb2Flag[try symbol(foundState)]
                lowCount = UInt32(hiCount)
                charMask[try symbol(state)] = escapeCount
                numMasked = stateCount
                foundState = 0
                for _ in 0..<(stateCount - 1) {
                    state -= Self.stateSize
                    charMask[try symbol(state)] = escapeCount
                }
                highCount = scale
                return true
            }
        }
        highCount = UInt32(hiCount)
        lowCount = UInt32(hiCount - (try freq(state)))
        try update1(context, state)
        return true
    }

    private mutating func update1(_ context: Int, _ state: Int) throws {
        foundState = state
        try setFreq(state, try freq(state) + 4)
        try setSummFreq(context, try summFreq(context) + 4)
        if try freq(state) > freq(state - Self.stateSize) {
            try swapStates(state, state - Self.stateSize)
            foundState = state - Self.stateSize
            if try freq(foundState) > Self.maxFrequency {
                try rescale(context)
            }
        }
    }

    private mutating func update2(_ context: Int, _ state: Int) throws {
        foundState = state
        let updated = try freq(state) + 4
        try setFreq(state, updated)
        try setSummFreq(context, try summFreq(context) + 4)
        if updated & 0xFF > Self.maxFrequency {
            try rescale(context)
        }
        escapeCount &+= 1
        runLength = initRunLength
    }

    /// `makeEscFreq2`: returns the SEE context index and sets `scale`.
    private mutating func makeEscFreq2(_ context: Int, difference: Int) throws -> Int {
        let stateCount = try numStats(context)
        if stateCount != 256 {
            guard difference >= 1, difference <= 256 else { throw RARError.corruptData("PPMd masked count") }
            let suffixStats = try numStats(try suffix(context))
            var index = ns2Index[difference - 1] * 16
            index += difference < suffixStats - stateCount ? 1 : 0
            index += 2 * (try summFreq(context) < 11 * stateCount ? 1 : 0)
            index += 4 * (numMasked > difference ? 1 : 0)
            index += hiBitsFlag
            guard index < see2.count else { throw RARError.corruptData("PPMd SEE context") }
            scale = see2[index].mean()
            return index
        }
        scale = 1
        return Self.dummySEE2
    }

    private mutating func decodeSymbol2() throws -> Bool {
        let context = minContext
        let stateCount = try numStats(context)
        if numMasked > stateCount { return false }
        var i = stateCount - numMasked
        // UnRAR loops on with i == 0 until it runs out of states and fails.
        if i <= 0 { return false }
        let see = try makeEscFreq2(context, difference: i)
        let first = try stats(context)
        let end = first + stateCount * Self.stateSize
        var candidates: [Int] = []
        candidates.reserveCapacity(i)
        var state = first - Self.stateSize
        var hiCount = 0
        repeat {
            repeat {
                state += Self.stateSize
                if state >= end { return false }
            } while charMask[try symbol(state)] == escapeCount
            hiCount += try freq(state)
            if candidates.count >= 256 { return false }
            candidates.append(state)
            i -= 1
        } while i > 0
        scale &+= UInt32(hiCount)
        let count = try currentCount()
        if count >= Int(Int32(bitPattern: scale)) { return false }
        if count < hiCount {
            hiCount = 0
            var position = 0
            state = candidates[0]
            while true {
                hiCount += try freq(state)
                if hiCount > count { break }
                position += 1
                if position >= candidates.count { return false }
                state = candidates[position]
            }
            highCount = UInt32(hiCount)
            lowCount = UInt32(hiCount - (try freq(state)))
            updateSEE(see)
            try update2(context, state)
        } else {
            lowCount = UInt32(hiCount)
            highCount = scale
            for candidate in candidates {
                charMask[try symbol(candidate)] = escapeCount
            }
            addToSEE(see, scale)
            numMasked = stateCount
        }
        return true
    }

    private mutating func updateSEE(_ index: Int) {
        if index == Self.dummySEE2 { dummy.update() } else { see2[index].update() }
    }

    private mutating func addToSEE(_ index: Int, _ value: UInt32) {
        let delta = UInt16(truncatingIfNeeded: value)
        if index == Self.dummySEE2 { dummy.summ &+= delta } else { see2[index].summ &+= delta }
    }

    private mutating func rescale(_ context: Int) throws {
        coverage.rescales += 1
        let oldCount = try numStats(context)
        let first = try stats(context)
        guard oldCount >= 2, foundState >= first,
              foundState < first + oldCount * Self.stateSize else {
            throw RARError.corruptData("PPMd rescale")
        }
        var state = foundState
        while state != first {
            try swapStates(state, state - Self.stateSize)
            state -= Self.stateSize
        }
        try setFreq(first, try freq(first) + 4)
        var summ = (try summFreq(context) + 4) & 0xFFFF
        var escape = summ - (try freq(first))
        let adder = orderFall != 0 ? 1 : 0
        var updated = (try freq(first) + adder) >> 1
        try setFreq(first, updated)
        summ = updated
        var i = oldCount - 1
        repeat {
            state += Self.stateSize
            escape -= try freq(state)
            updated = (try freq(state) + adder) >> 1
            try setFreq(state, updated)
            summ += updated
            if try freq(state) > freq(state - Self.stateSize) {
                let (tmpSymbol, tmpFreq, tmpSuccessor) = (try symbol(state), try freq(state), try successor(state))
                var slot = state
                repeat {
                    try copyState(from: slot - Self.stateSize, to: slot)
                    slot -= Self.stateSize
                } while try slot != first && tmpFreq > freq(slot - Self.stateSize)
                try setSymbol(slot, tmpSymbol)
                try setFreq(slot, tmpFreq)
                try setSuccessor(slot, tmpSuccessor)
            }
            i -= 1
        } while i > 0
        var stateCount = oldCount
        if try freq(state) == 0 {
            i = 0
            repeat {
                i += 1
                state -= Self.stateSize
            } while try freq(state) == 0
            escape += i
            stateCount -= i
            try setNumStats(context, stateCount)
            if stateCount == 1 {
                let (tmpSymbol, tmpFreqStart, tmpSuccessor) = (try symbol(first), try freq(first), try successor(first))
                var tmpFreq = tmpFreqStart
                repeat {
                    tmpFreq -= tmpFreq >> 1
                    escape >>= 1
                } while escape > 1
                try heap.freeUnits(first, count: (oldCount + 1) >> 1)
                foundState = oneState(context)
                try setSymbol(foundState, tmpSymbol)
                try setFreq(foundState, tmpFreq)
                try setSuccessor(foundState, tmpSuccessor)
                return
            }
        }
        escape -= escape >> 1
        summ += escape
        try setSummFreq(context, summ)
        let n0 = (oldCount + 1) >> 1, n1 = (stateCount + 1) >> 1
        var newStats = first
        if n0 != n1 {
            newStats = try heap.shrinkUnits(first, oldCount: n0, newCount: n1)
            try setStats(context, newStats)
        }
        foundState = newStats
    }

    /// `CreateSuccessors`. Returns 0 where UnRAR returns NULL.
    private mutating func createSuccessors(skip: Bool, _ p1: Int) throws -> Int {
        var context = minContext
        let upBranch = try successor(foundState)
        let foundSymbol = try symbol(foundState)
        var chain: [Int] = []
        var state = 0
        var runLoop = true
        var atLoopEntry = false
        if !skip {
            chain.append(foundState)
            if try suffix(context) == 0 { runLoop = false }
        }
        if runLoop, p1 != 0 {
            state = p1
            context = try suffix(context)
            atLoopEntry = true
        }
        while runLoop {
            if !atLoopEntry {
                context = try suffix(context)
                if try numStats(context) != 1 {
                    state = try findState(in: context, symbol: foundSymbol)
                } else {
                    state = oneState(context)
                }
            }
            atLoopEntry = false
            let next = try successor(state)
            if next != upBranch {
                context = next
                break
            }
            if chain.count >= Self.maxOrder { return 0 }
            chain.append(state)
            if try suffix(context) == 0 { break }
        }
        if chain.isEmpty { return context }

        let upSymbol = try heap.byte(upBranch)
        let upSuccessor = upBranch + 1
        let upFreq: Int
        if try numStats(context) != 1 {
            if context <= heap.pText { return 0 }
            let found = try findState(in: context, symbol: upSymbol)
            let cf = UInt32(truncatingIfNeeded: try freq(found) - 1)
            let s0 = UInt32(truncatingIfNeeded: try summFreq(context) - numStats(context)) &- cf
            if 2 &* cf <= s0 {
                upFreq = 1 + (5 &* cf > s0 ? 1 : 0)
            } else {
                guard s0 != 0 else { throw RARError.corruptData("PPMd successor frequency") }
                // Split up: Swift 6.2 cannot type-check it as one expression.
                let numerator: UInt32 = 2 &* cf &+ 3 &* s0 &- 1
                let denominator: UInt32 = 2 &* s0
                upFreq = 1 + Int(numerator / denominator)
            }
        } else {
            upFreq = try freq(oneState(context))
        }
        while let parent = chain.popLast() {
            let child = try heap.allocContext()
            if child == 0 { return 0 }
            try setNumStats(child, 1)
            let inline = oneState(child)
            try setSymbol(inline, upSymbol)
            try setFreq(inline, upFreq)
            try setSuccessor(inline, upSuccessor)
            try setSuffix(child, context)
            try setSuccessor(parent, child)
            context = child
        }
        return context
    }

    private mutating func updateModel() throws {
        let fsSymbol = try symbol(foundState)
        let fsFreq = try freq(foundState)
        var fsSuccessor = try successor(foundState)
        var p = 0
        if fsFreq < Self.maxFrequency / 4 {
            let context = try suffix(minContext)
            if context != 0 {
                if try numStats(context) != 1 {
                    p = try stats(context)
                    if try symbol(p) != fsSymbol {
                        p = try findState(in: context, symbol: fsSymbol)
                        if try freq(p) >= freq(p - Self.stateSize) {
                            try swapStates(p, p - Self.stateSize)
                            p -= Self.stateSize
                        }
                    }
                    if try freq(p) < Self.maxFrequency - 9 {
                        try setFreq(p, try freq(p) + 2)
                        try setSummFreq(context, try summFreq(context) + 2)
                    }
                } else {
                    p = oneState(context)
                    let pFreq = try freq(p)
                    try setFreq(p, pFreq + (pFreq < 32 ? 1 : 0))
                }
            }
        }
        if orderFall == 0 {
            let created = try createSuccessors(skip: true, p)
            minContext = created
            maxContext = created
            if created == 0 { return try restartAfterOverflow() }
            try setSuccessor(foundState, created)
            return
        }
        try heap.setByte(heap.pText, fsSymbol)
        heap.pText += 1
        var successorContext = heap.pText
        if heap.pText >= heap.fakeUnitsStart { return try restartAfterOverflow() }
        if fsSuccessor != 0 {
            if fsSuccessor <= heap.pText {
                fsSuccessor = try createSuccessors(skip: false, p)
                if fsSuccessor == 0 { return try restartAfterOverflow() }
            }
            orderFall -= 1
            if orderFall == 0 {
                successorContext = fsSuccessor
                if maxContext != minContext { heap.pText -= 1 }
            }
        } else {
            try setSuccessor(foundState, successorContext)
            fsSuccessor = minContext
        }

        let ns = try numStats(minContext)
        let s0 = UInt32(truncatingIfNeeded: try summFreq(minContext) - ns - (fsFreq - 1))
        var context = maxContext
        var steps = 0
        while context != minContext {
            steps += 1
            guard steps <= Self.maxOrder + 1 else { throw RARError.corruptData("PPMd context chain") }
            var ns1 = try numStats(context)
            if ns1 != 1 {
                if ns1 & 1 == 0 {
                    let expanded = try heap.expandUnits(try stats(context), oldCount: ns1 >> 1)
                    if expanded == 0 { return try restartAfterOverflow() }
                    try setStats(context, expanded)
                }
                var summ = try summFreq(context)
                summ += (2 * ns1 < ns ? 1 : 0) + 2 * ((4 * ns1 <= ns ? 1 : 0) & (summ <= 8 * ns1 ? 1 : 0))
                try setSummFreq(context, summ)
            } else {
                let moved = try heap.allocUnits(1)
                if moved == 0 { return try restartAfterOverflow() }
                try copyState(from: oneState(context), to: moved)
                try setStats(context, moved)
                let movedFreq = try freq(moved)
                try setFreq(moved, movedFreq < Self.maxFrequency / 4 - 1 ? movedFreq + movedFreq : Self.maxFrequency - 4)
                try setSummFreq(context, try freq(moved) + initEscape + (ns > 3 ? 1 : 0))
            }
            let summ = UInt32(try summFreq(context))
            var cf = 2 &* UInt32(fsFreq) &* (summ &+ 6)
            let sf = s0 &+ summ
            if cf < 6 &* sf {
                cf = 1 + (cf > sf ? 1 : 0) + (cf >= 4 &* sf ? 1 : 0)
                try setSummFreq(context, Int(summ) + 3)
            } else {
                cf = 4 + (cf >= 9 &* sf ? 1 : 0) + (cf >= 12 &* sf ? 1 : 0) + (cf >= 15 &* sf ? 1 : 0)
                try setSummFreq(context, Int(summ) + Int(cf))
            }
            let added = try stats(context) + ns1 * Self.stateSize
            try setSuccessor(added, successorContext)
            try setSymbol(added, fsSymbol)
            try setFreq(added, Int(cf))
            ns1 += 1
            try setNumStats(context, ns1)
            context = try suffix(context)
        }
        maxContext = fsSuccessor
        minContext = fsSuccessor
    }

    /// `RESTART_MODEL`.
    private mutating func restartAfterOverflow() throws {
        coverage.restarts += 1
        try restartModel()
        escapeCount = 0
    }
}
