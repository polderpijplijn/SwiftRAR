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
// Ported from UnRAR's suballoc.cpp (PPMd memory allocator by Dmitry
// Shkarin, public domain, as adapted by UnRAR).

import RARCore

/// The PPMd model memory: one byte array addressed by integer offsets
/// instead of pointers, with the PPMd suballocator on top.
///
/// The model compares addresses (a successor at or below `pText` is a
/// position in the text area, not a context), so every object lives in
/// this one array. Offset 0 is NULL. Bytes 0..<12 hold the list sentinel
/// of `glueFreeBlocks`; the heap proper starts at offset 12, so no object
/// ever has offset 0. Units are 12 bytes, the size the original algorithm
/// was written for.
///
/// Every access is checked and throws `.corruptData` outside the heap.
struct PPMdHeap {
    static let unitSize = 12
    static let base = unitSize
    static let n1 = 4, n2 = 4, n3 = 4, n4 = (128 + 3 - 1 * n1 - 2 * n2 - 3 * n3) / 4
    static let indexCount = n1 + n2 + n3 + n4

    static let indexToUnits: [Int] = {
        var table: [Int] = []
        var k = 1
        for _ in 0..<n1 { table.append(k); k += 1 }
        k += 1
        for _ in 0..<n2 { table.append(k); k += 2 }
        k += 1
        for _ in 0..<n3 { table.append(k); k += 3 }
        k += 1
        for _ in 0..<n4 { table.append(k); k += 4 }
        return table
    }()

    static let unitsToIndex: [Int] = {
        var table: [Int] = []
        var i = 0
        for k in 0..<128 {
            if indexToUnits[i] < k + 1 { i += 1 }
            table.append(i)
        }
        return table
    }()

    private(set) var bytes: [UInt8] = []
    /// Model memory in bytes as the header asked for (SubAllocatorSize);
    /// zero when nothing is allocated.
    private(set) var allocatorSize = 0
    private(set) var heapEnd = 0

    var pText = 0
    private(set) var unitsStart = 0
    private(set) var fakeUnitsStart = 0
    private var loUnit = 0
    private var hiUnit = 0
    private var freeList = [Int](repeating: 0, count: indexCount)
    private var glueCount: UInt8 = 0

    /// Coverage counters for tests.
    private(set) var glueRuns = 0
    private(set) var textAreaAllocations = 0

    // MARK: - Checked access

    @inline(__always)
    func byte(_ offset: Int) throws -> Int {
        guard offset >= Self.base, offset < bytes.count else { throw RARError.corruptData("PPMd reference") }
        return Int(bytes[offset])
    }

    @inline(__always)
    mutating func setByte(_ offset: Int, _ value: Int) throws {
        guard offset >= Self.base, offset < bytes.count else { throw RARError.corruptData("PPMd reference") }
        bytes[offset] = UInt8(truncatingIfNeeded: value)
    }

    @inline(__always)
    func u16(_ offset: Int) throws -> Int {
        guard offset >= Self.base, offset < bytes.count - 1 else { throw RARError.corruptData("PPMd reference") }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    @inline(__always)
    mutating func setU16(_ offset: Int, _ value: Int) throws {
        guard offset >= Self.base, offset < bytes.count - 1 else { throw RARError.corruptData("PPMd reference") }
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    @inline(__always)
    func u32(_ offset: Int) throws -> Int {
        guard offset >= Self.base, offset < bytes.count - 3 else { throw RARError.corruptData("PPMd reference") }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    @inline(__always)
    mutating func setU32(_ offset: Int, _ value: Int) throws {
        guard offset >= Self.base, offset < bytes.count - 3 else { throw RARError.corruptData("PPMd reference") }
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    /// Copies `count` bytes inside the heap (memcpy; the ranges never overlap).
    mutating func copyBytes(from source: Int, to target: Int, count: Int) throws {
        guard count > 0 else { return }
        guard source >= Self.base, target >= Self.base,
              source <= bytes.count - count, target <= bytes.count - count else {
            throw RARError.corruptData("PPMd reference")
        }
        for index in 0..<count {
            bytes[target + index] = bytes[source + index]
        }
    }

    // MARK: - Free lists (RAR_NODE: `next` at offset 0)

    private mutating func insertNode(_ node: Int, _ index: Int) throws {
        try setU32(node, freeList[index])
        freeList[index] = node
    }

    private mutating func removeNode(_ index: Int) throws -> Int {
        let node = freeList[index]
        freeList[index] = try u32(node)
        return node
    }

    // MARK: - Memory blocks (RARPPM_MEM_BLK: Stamp, NU, next, prev)
    // The sentinel lives at offset 0, below `base`, so these use raw access.

    private func blockField(_ block: Int, _ field: Int, size: Int) throws -> Int {
        let offset = block + field
        guard offset >= 0, offset <= bytes.count - size else { throw RARError.corruptData("PPMd reference") }
        var value = 0
        for index in 0..<size { value |= Int(bytes[offset + index]) << (8 * index) }
        return value
    }

    private mutating func setBlockField(_ block: Int, _ field: Int, size: Int, _ value: Int) throws {
        let offset = block + field
        guard offset >= 0, offset <= bytes.count - size else { throw RARError.corruptData("PPMd reference") }
        for index in 0..<size { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    private func stamp(_ block: Int) throws -> Int { try blockField(block, 0, size: 2) }
    private func units(_ block: Int) throws -> Int { try blockField(block, 2, size: 2) }
    private func next(_ block: Int) throws -> Int { try blockField(block, 4, size: 4) }
    private func prev(_ block: Int) throws -> Int { try blockField(block, 8, size: 4) }
    private mutating func setStamp(_ block: Int, _ value: Int) throws { try setBlockField(block, 0, size: 2, value) }
    private mutating func setUnits(_ block: Int, _ value: Int) throws { try setBlockField(block, 2, size: 2, value) }
    private mutating func setNext(_ block: Int, _ value: Int) throws { try setBlockField(block, 4, size: 4, value) }
    private mutating func setPrev(_ block: Int, _ value: Int) throws { try setBlockField(block, 8, size: 4, value) }

    /// `insertAt`: links `block` in right after `list`.
    private mutating func link(_ block: Int, after list: Int) throws {
        let following = try next(list)
        try setPrev(block, list)
        try setNext(block, following)
        try setPrev(following, block)
        try setNext(list, block)
    }

    private mutating func unlink(_ block: Int) throws {
        let before = try prev(block)
        let after = try next(block)
        try setNext(before, after)
        try setPrev(after, before)
    }

    // MARK: - Allocator

    /// `StartSubAllocator`: (re)allocates `megabytes` MiB unless the heap
    /// already has that size.
    mutating func start(megabytes: Int) {
        let size = megabytes << 20
        if allocatorSize == size { return }
        let allocSize = size / Self.unitSize * Self.unitSize + 2 * Self.unitSize
        bytes = [UInt8](repeating: 0, count: Self.base + allocSize)
        heapEnd = Self.base + allocSize - Self.unitSize
        allocatorSize = size
    }

    /// `StopSubAllocator`.
    mutating func stop() {
        bytes = []
        allocatorSize = 0
        heapEnd = 0
    }

    /// `InitSubAllocator`.
    mutating func reset() {
        freeList = [Int](repeating: 0, count: Self.indexCount)
        pText = Self.base
        let size2 = Self.unitSize * (allocatorSize / 8 / Self.unitSize * 7)
        let size1 = allocatorSize - size2
        let realSize1 = size1 / Self.unitSize * Self.unitSize + Self.unitSize
        loUnit = Self.base + realSize1
        unitsStart = loUnit
        fakeUnitsStart = Self.base + size1
        hiUnit = loUnit + size2
        glueCount = 0
    }

    private mutating func splitBlock(_ block: Int, oldIndex: Int, newIndex: Int) throws {
        var difference = Self.indexToUnits[oldIndex] - Self.indexToUnits[newIndex]
        var position = block + Self.unitSize * Self.indexToUnits[newIndex]
        var index = Self.unitsToIndex[difference - 1]
        if Self.indexToUnits[index] != difference {
            index -= 1
            try insertNode(position, index)
            position += Self.unitSize * Self.indexToUnits[index]
            difference -= Self.indexToUnits[index]
        }
        try insertNode(position, Self.unitsToIndex[difference - 1])
    }

    private mutating func glueFreeBlocks() throws {
        glueRuns += 1
        let sentinel = 0
        if loUnit != hiUnit {
            try setByte(loUnit, 0)
        }
        try setNext(sentinel, sentinel)
        try setPrev(sentinel, sentinel)
        for index in 0..<Self.indexCount {
            while freeList[index] != 0 {
                let block = try removeNode(index)
                try link(block, after: sentinel)
                try setStamp(block, 0xFFFF)
                try setUnits(block, Self.indexToUnits[index])
            }
        }

        var block = try next(sentinel)
        while block != sentinel {
            while true {
                let count = try units(block)
                let following = block + Self.unitSize * count
                guard try stamp(following) == 0xFFFF else { break }
                let followingCount = try units(following)
                guard count + followingCount < 0x10000 else { break }
                try unlink(following)
                try setUnits(block, count + followingCount)
            }
            block = try next(block)
        }

        while try next(sentinel) != sentinel {
            var block = try next(sentinel)
            try unlink(block)
            var size = try units(block)
            while size > 128 {
                try insertNode(block, Self.indexCount - 1)
                size -= 128
                block += Self.unitSize * 128
            }
            var index = Self.unitsToIndex[size - 1]
            if Self.indexToUnits[index] != size {
                index -= 1
                let rest = size - Self.indexToUnits[index]
                try insertNode(block + Self.unitSize * (size - rest), rest - 1)
            }
            try insertNode(block, index)
        }
    }

    /// `AllocUnitsRare`. Returns 0 when memory is exhausted.
    private mutating func allocUnitsRare(_ index: Int) throws -> Int {
        if glueCount == 0 {
            glueCount = 255
            try glueFreeBlocks()
            if freeList[index] != 0 {
                return try removeNode(index)
            }
        }
        var i = index
        repeat {
            i += 1
            if i == Self.indexCount {
                glueCount &-= 1
                let size = Self.unitSize * Self.indexToUnits[index]
                if fakeUnitsStart - pText > size {
                    fakeUnitsStart -= size
                    unitsStart -= size
                    textAreaAllocations += 1
                    return unitsStart
                }
                return 0
            }
        } while freeList[i] == 0
        let block = try removeNode(i)
        try splitBlock(block, oldIndex: i, newIndex: index)
        return block
    }

    /// `AllocUnits`. Returns 0 when memory is exhausted.
    mutating func allocUnits(_ count: Int) throws -> Int {
        guard count >= 1, count <= 128 else { throw RARError.corruptData("PPMd allocation of \(count) units") }
        let index = Self.unitsToIndex[count - 1]
        if freeList[index] != 0 {
            return try removeNode(index)
        }
        let block = loUnit
        let size = Self.unitSize * Self.indexToUnits[index]
        if loUnit + size <= hiUnit {
            loUnit += size
            return block
        }
        return try allocUnitsRare(index)
    }

    /// `AllocContext`. Returns 0 when memory is exhausted.
    mutating func allocContext() throws -> Int {
        if hiUnit != loUnit {
            hiUnit -= Self.unitSize
            return hiUnit
        }
        if freeList[0] != 0 {
            return try removeNode(0)
        }
        return try allocUnitsRare(0)
    }

    /// `ExpandUnits`. Returns 0 when memory is exhausted.
    mutating func expandUnits(_ block: Int, oldCount: Int) throws -> Int {
        guard oldCount >= 1, oldCount < 128 else { throw RARError.corruptData("PPMd expansion of \(oldCount) units") }
        let oldIndex = Self.unitsToIndex[oldCount - 1]
        if oldIndex == Self.unitsToIndex[oldCount] {
            return block
        }
        let moved = try allocUnits(oldCount + 1)
        if moved != 0 {
            try copyBytes(from: block, to: moved, count: Self.unitSize * oldCount)
            try insertNode(block, oldIndex)
        }
        return moved
    }

    /// `ShrinkUnits`.
    mutating func shrinkUnits(_ block: Int, oldCount: Int, newCount: Int) throws -> Int {
        guard newCount >= 1, oldCount <= 128, newCount <= oldCount else {
            throw RARError.corruptData("PPMd shrink of \(oldCount) to \(newCount) units")
        }
        let oldIndex = Self.unitsToIndex[oldCount - 1]
        let newIndex = Self.unitsToIndex[newCount - 1]
        if oldIndex == newIndex {
            return block
        }
        if freeList[newIndex] != 0 {
            let moved = try removeNode(newIndex)
            try copyBytes(from: block, to: moved, count: Self.unitSize * newCount)
            try insertNode(block, oldIndex)
            return moved
        }
        try splitBlock(block, oldIndex: oldIndex, newIndex: newIndex)
        return block
    }

    /// `FreeUnits`.
    mutating func freeUnits(_ block: Int, count: Int) throws {
        guard count >= 1, count <= 128 else { throw RARError.corruptData("PPMd free of \(count) units") }
        try insertNode(block, Self.unitsToIndex[count - 1])
    }
}
