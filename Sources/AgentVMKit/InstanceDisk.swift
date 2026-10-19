//
//  InstanceDisk.swift
//  How full an instance's disk is, read from outside the VM.
//
//  An instance's root filesystem is an ext4 image: a sparse file the container
//  service sizes at 512 GiB. The space that file takes on this Mac says little
//  about how full the disk is — a fresh image already has a gigabyte of
//  journal and inode tables written, and blocks the guest frees are never
//  handed back. So the figures come from the filesystem's own accounting
//  instead: its superblock and block-group descriptors, a few hundred
//  kilobytes at the start of the image. They give what `df /` prints inside
//  the guest, to the block.
//
//  While the VM runs, its kernel writes those counts back lazily, so they
//  trail the guest by a minute or so. A stopped instance's are exact.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import ContainerizationEXT4
import Foundation

public struct InstanceDisk: Sendable, Equatable {
    /// The filesystem's size, less what ext4 keeps for itself: `df`'s Size.
    public var capacity: UInt64
    /// What the files on it take: `df`'s Used.
    public var used: UInt64
    /// The space the image takes on this Mac, ext4's own structures included.
    public var onHost: UInt64?

    public init(capacity: UInt64, used: UInt64, onHost: UInt64? = nil) {
        self.capacity = capacity
        self.used = min(used, capacity)
        self.onHost = onHost
    }

    /// `used` as a share of `capacity`, 0…1.
    public var share: Double { capacity > 0 ? Double(used) / Double(capacity) : 0 }
    public var available: UInt64 { capacity - used }

    /// The figures for the ext4 image at `url`, or nil if it isn't one this
    /// can count.
    public static func read(imageAt url: URL) -> InstanceDisk? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = MemoryLayout<EXT4.SuperBlock>.size
        guard (try? handle.seek(toOffset: EXT4Layout.superBlockOffset)) != nil,
            let data = try? handle.read(upToCount: size), data.count == size
        else { return nil }
        let superBlock = data.withUnsafeBytes { $0.loadLittleEndian(as: EXT4.SuperBlock.self) }
        guard let layout = EXT4Layout(superBlock) else { return nil }

        guard (try? handle.seek(toOffset: layout.descriptorTableOffset)) != nil,
            let table = try? handle.read(upToCount: layout.descriptorTableSize),
            table.count == layout.descriptorTableSize
        else { return nil }

        let onHost = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
        return layout.disk(freeBlocks: layout.freeBlocks(inDescriptorTable: table), onHost: onHost.map(UInt64.init))
    }
}

/// The parts of an ext4 superblock that counting needs, checked for sense: a
/// torn read, or a file that isn't ext4 at all, gives nil rather than a number.
struct EXT4Layout: Equatable {
    static let superBlockOffset: UInt64 = 1024

    let blockSize: UInt64
    let blocks: UInt64
    let firstDataBlock: UInt64
    let blocksPerGroup: UInt64
    let groups: UInt64
    let descriptorSize: Int
    /// Blocks ext4 keeps for itself: what `df` leaves out of Size.
    let overhead: UInt64

    // Feature flags, from the ext4 on-disk format.
    private static let compatHasJournal: UInt32 = 0x4
    private static let compatSparseSuper2: UInt32 = 0x200
    private static let incompatMetaBG: UInt32 = 0x10
    private static let incompat64Bit: UInt32 = 0x80
    private static let roCompatSparseSuper: UInt32 = 0x1
    private static let roCompatBigAlloc: UInt32 = 0x200
    /// `s_jnl_backup_type` when the superblock keeps a copy of the journal
    /// inode's block map and size.
    private static let journalBackupBlocks: UInt8 = 1

    init?(_ sb: EXT4.SuperBlock) {
        guard sb.magic == EXT4.SuperBlockMagic, sb.logBlockSize <= 6 else { return nil }
        // Layouts this doesn't count: clusters, and descriptor tables spread
        // through the disk. The container service makes neither.
        guard sb.featureRoCompat & Self.roCompatBigAlloc == 0, sb.featureIncompat & Self.incompatMetaBG == 0 else {
            return nil
        }
        let is64Bit = sb.featureIncompat & Self.incompat64Bit != 0
        blockSize = 1024 << UInt64(sb.logBlockSize)
        blocks = UInt64(sb.blocksCountLow) | (is64Bit ? UInt64(sb.blocksCountHigh) << 32 : 0)
        firstDataBlock = UInt64(sb.firstDataBlock)
        blocksPerGroup = UInt64(sb.blocksPerGroup)
        // One bitmap block maps a group, so a group can't be larger than that.
        guard blocks > firstDataBlock, blocksPerGroup > 0, blocksPerGroup <= blockSize * 8 else { return nil }
        groups = (blocks - firstDataBlock + blocksPerGroup - 1) / blocksPerGroup
        descriptorSize = is64Bit ? Int(sb.descSize) : 32
        guard descriptorSize >= 32, descriptorSize <= 1024,
            groups <= UInt64(Self.maximumTableSize / descriptorSize)
        else { return nil }

        let inodeSize = UInt64(sb.revisionLevel == 0 ? 128 : sb.inodeSize)
        let inodeTableBlocks = (UInt64(sb.inodesPerGroup) * inodeSize + blockSize - 1) / blockSize
        let descriptorBlocks = (groups * UInt64(descriptorSize) + blockSize - 1) / blockSize

        // The journal's size, from the superblock's copy of its inode.
        var journalBlocks: UInt64 = 0
        if sb.featureCompat & Self.compatHasJournal != 0 {
            if sb.journalBackupType == Self.journalBackupBlocks {
                let bytes = UInt64(sb.journalBlocks.15) << 32 | UInt64(sb.journalBlocks.16)
                journalBlocks = bytes / blockSize
            } else if sb.overheadBlocks == 0 {
                // No size to hand and no count stored: nothing to go on.
                return nil
            }
        }

        // As the kernel's ext4_calculate_overhead counts it: everything
        // before the first group, then in each group a copy of the superblock
        // and descriptors where it keeps one, its two bitmaps and its inode
        // table, and finally the journal.
        let sparseSuper2 = sb.featureCompat & Self.compatSparseSuper2 != 0
        let sparseSuper = sb.featureRoCompat & Self.roCompatSparseSuper != 0
        let backups = [UInt64(sb.backupBgs.0), UInt64(sb.backupBgs.1)].filter { $0 != 0 }
        var copies: UInt64 = 0
        for group in 0..<groups
        where Self.hasSuperBlock(group, sparseSuper: sparseSuper, sparseSuper2: sparseSuper2, backups: backups) {
            copies += 1
        }
        let computed =
            firstDataBlock + copies * (1 + descriptorBlocks + UInt64(sb.reservedGdtBlocks))
            + groups * (inodeTableBlocks + 2) + journalBlocks
        // A count the kernel stored wins: it saw the journal inode itself.
        let stored = UInt64(sb.overheadBlocks)
        overhead = stored > 0 && stored < blocks ? stored : computed
        guard overhead < blocks else { return nil }
    }

    /// At most this much descriptor table is read: 64 MiB, far past the
    /// 130 KiB of a 512 GiB disk.
    private static let maximumTableSize = 64 << 20

    var descriptorTableOffset: UInt64 { (firstDataBlock + 1) * blockSize }
    var descriptorTableSize: Int { Int(groups) * descriptorSize }

    /// Which groups keep a copy of the superblock: all of them, or with
    /// sparse_super only 0, 1 and powers of 3, 5 and 7, or with
    /// sparse_super2 only 0 and the two it names.
    static func hasSuperBlock(_ group: UInt64, sparseSuper: Bool, sparseSuper2: Bool, backups: [UInt64]) -> Bool {
        if group == 0 { return true }
        if sparseSuper2 { return backups.contains(group) }
        if !sparseSuper { return true }
        if group == 1 { return true }
        return [3, 5, 7].contains { isPower(group, of: $0) }
    }

    private static func isPower(_ value: UInt64, of base: UInt64) -> Bool {
        var value = value
        while value > 1, value % base == 0 { value /= base }
        return value == 1
    }

    /// Free blocks, from the group descriptors rather than the superblock's
    /// total: a mounted filesystem keeps the superblock's stale until it's
    /// unmounted, but writes the descriptors back as it goes.
    func freeBlocks(inDescriptorTable table: Data) -> UInt64 {
        table.withUnsafeBytes { bytes in
            var free: UInt64 = 0
            for group in 0..<Int(groups) {
                let base = group * descriptorSize
                let low = UInt64(bytes.loadUnaligned(fromByteOffset: base + 0x0C, as: UInt16.self).littleEndian)
                let high =
                    descriptorSize >= 64
                    ? UInt64(bytes.loadUnaligned(fromByteOffset: base + 0x2C, as: UInt16.self).littleEndian) : 0
                free += low | high << 16
            }
            return free
        }
    }

    func disk(freeBlocks: UInt64, onHost: UInt64?) -> InstanceDisk? {
        guard freeBlocks <= blocks else { return nil }
        let capacity = blocks - overhead
        let used = blocks - freeBlocks > overhead ? blocks - freeBlocks - overhead : 0
        return InstanceDisk(capacity: capacity * blockSize, used: used * blockSize, onHost: onHost)
    }
}
