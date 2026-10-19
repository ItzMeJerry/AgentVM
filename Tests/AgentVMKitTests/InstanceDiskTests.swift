//
//  InstanceDiskTests.swift
//  How full an instance's disk is, read from its image. The images here are
//  made by the container service's own ext4 formatter, so they are laid out
//  exactly as an instance's disk is.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import AgentVMKit

@Suite("Instance disk")
struct InstanceDiskTests {
    private func temporaryImage() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "agentvm-disk-\(UUID().uuidString).ext4")
    }

    /// An image holding one file of `bytes` bytes, formatted the way the
    /// container service formats an instance's disk: with a journal.
    private func image(holding bytes: Int, size: UInt64 = 64 << 20) throws -> URL {
        let url = temporaryImage()
        let formatter = try EXT4.Formatter(
            FilePath(url.path(percentEncoded: false)), minDiskSize: size, journal: .init(defaultMode: .ordered))
        if bytes > 0 {
            let stream = InputStream(data: Data(repeating: 0x5A, count: bytes))
            stream.open()
            defer { stream.close() }
            try formatter.create(path: FilePath("/payload"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream)
        }
        try formatter.close()
        return url
    }

    @Test("A file on the disk counts as used, to within a few blocks of its size")
    func used() throws {
        let empty = try image(holding: 0)
        let full = try image(holding: 8 << 20)
        defer {
            try? FileManager.default.removeItem(at: empty)
            try? FileManager.default.removeItem(at: full)
        }
        let before = try #require(InstanceDisk.read(imageAt: empty))
        let after = try #require(InstanceDisk.read(imageAt: full))
        let grew = Int64(after.used) - Int64(before.used)
        // 8 MiB of data, plus at most a few blocks of extent tree.
        #expect(grew >= 8 << 20, "before \(before), after \(after)")
        #expect(after.capacity == before.capacity, "the same disk, so the same room")
        #expect(grew <= (8 << 20) + 64 * 1_024)
        #expect(before.used < 1 << 20, "an empty disk is nearly empty: root and lost+found")
    }

    @Test("What ext4 keeps for itself — journal, inode tables — is not counted as used, or as room")
    func overheadIsNotUsed() throws {
        let url = try image(holding: 0, size: 256 << 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = try #require(InstanceDisk.read(imageAt: url))
        let imageSize = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(disk.capacity < UInt64(imageSize), "the journal and tables come off the top")
        #expect(disk.capacity > UInt64(imageSize) / 2)
        #expect(disk.share < 0.01)
        #expect(disk.available == disk.capacity - disk.used)
    }

    @Test("The space on this Mac is the image's own, journal and all")
    func onHost() throws {
        let url = try image(holding: 1 << 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = try #require(InstanceDisk.read(imageAt: url))
        let onHost = try #require(disk.onHost)
        #expect(onHost > disk.used, "a fresh image has written its journal and tables")
    }

    @Test("Overhead is counted as Linux counts it, matching what it stored for a real instance's 512 GiB disk")
    func linuxOverhead() throws {
        // The superblock fields of an instance disk the container service made,
        // and the overhead Linux wrote back into it after mounting it.
        var raw = Data(count: MemoryLayout<EXT4.SuperBlock>.size)
        func put32(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { raw.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        func put16(_ value: UInt16, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { raw.replaceSubrange(offset..<offset + 2, with: $0) }
        }
        put32(134_479_872, at: 0x04)  // blocks
        put32(2, at: 0x18)  // 4 KiB blocks
        put32(32_768, at: 0x20)  // blocks per group
        put32(8_192, at: 0x28)  // inodes per group
        put16(0xEF53, at: 0x38)
        put32(1, at: 0x4C)  // revision 1: inode size is stored
        put16(256, at: 0x58)
        put32(0x4 | 0x200, at: 0x5C)  // journal, sparse_super2
        put32(0x2 | 0x40 | 0x200, at: 0x60)  // filetype, extents, flex_bg
        raw[0xFD] = 1  // journal inode backup kept
        put32(0, at: 0x10C + 15 * 4)
        put32(1 << 30, at: 0x10C + 16 * 4)  // a 1 GiB journal
        let superBlock = raw.withUnsafeBytes { $0.loadLittleEndian(as: EXT4.SuperBlock.self) }

        let layout = try #require(EXT4Layout(superBlock))
        #expect(layout.groups == 4_104)
        #expect(layout.overhead == 2_371_634, "what Linux stored in s_overhead_clusters")
        let disk = try #require(layout.disk(freeBlocks: 132_105_919, onHost: nil))
        #expect(disk.capacity == 528_432_952 * 1_024, "df's 1K-blocks for that disk")
        #expect(disk.used == 2_319 * 4_096, "alpine's files")
    }

    @Test("Superblock backups follow sparse_super's rule: 0, 1, and powers of 3, 5 and 7")
    func backups() {
        let groups = (0..<60).filter {
            EXT4Layout.hasSuperBlock(UInt64($0), sparseSuper: true, sparseSuper2: false, backups: [])
        }
        #expect(groups == [0, 1, 3, 5, 7, 9, 25, 27, 49])
        #expect(EXT4Layout.hasSuperBlock(12, sparseSuper: false, sparseSuper2: false, backups: []))
        #expect(!EXT4Layout.hasSuperBlock(12, sparseSuper: false, sparseSuper2: true, backups: []))
        #expect(EXT4Layout.hasSuperBlock(12, sparseSuper: false, sparseSuper2: true, backups: [12]))
    }

    @Test("Anything that isn't an ext4 image reads as nothing, not as a number")
    func notExt4() throws {
        let missing = temporaryImage()
        #expect(InstanceDisk.read(imageAt: missing) == nil)

        let junk = temporaryImage()
        try Data((0..<8_192).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(InstanceDisk.read(imageAt: junk) == nil)

        let short = temporaryImage()
        try Data(count: 600).write(to: short)
        defer { try? FileManager.default.removeItem(at: short) }
        #expect(InstanceDisk.read(imageAt: short) == nil)
    }

    @Test("A disk's share never passes the whole of it")
    func share() {
        #expect(InstanceDisk(capacity: 100, used: 250).used == 100)
        #expect(InstanceDisk(capacity: 100, used: 25).share == 0.25)
        #expect(InstanceDisk(capacity: 0, used: 0).share == 0)
    }
}
