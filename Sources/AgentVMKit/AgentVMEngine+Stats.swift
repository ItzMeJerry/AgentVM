//
//  AgentVMEngine+Stats.swift
//  Readings for the dashboard: an instance's counters and disk use, and what
//  the container service stores. One XPC request each, through the client
//  the rest of the engine uses.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import ContainerAPIClient
import Foundation

extension AgentVMEngine {
    /// A running instance's counters, stamped with when they were read.
    public func resourceSample(for fullName: String) async throws -> ResourceSample {
        let stats = try await containers.stats(id: fullName)
        return ResourceSample(
            time: Date(),
            cpuMicroseconds: stats.cpuUsageUsec,
            memoryUsed: stats.memoryUsageBytes,
            memoryLimit: stats.memoryLimitBytes,
            bytesReceived: stats.networkRxBytes,
            bytesSent: stats.networkTxBytes,
            bytesRead: stats.blockReadBytes,
            bytesWritten: stats.blockWriteBytes,
            processes: stats.numProcesses)
    }

    /// The space an instance's whole bundle takes on this Mac — its disk, its
    /// kernel and its init filesystem — in bytes.
    public func diskUsage(of fullName: String) async throws -> UInt64 {
        try await containers.diskUsage(id: fullName)
    }

    /// How full an instance's own disk is, as `df /` inside it would say. Read
    /// from the disk image in the container service's bundle; there is no
    /// API for it. Nil until the instance has first started, which is when
    /// the service makes its disk.
    public func rootDisk(of fullName: String) async -> InstanceDisk? {
        guard let root = await containersRoot() else { return nil }
        let image = root.appendingPathComponent(fullName, isDirectory: true).appendingPathComponent("rootfs.ext4")
        return InstanceDisk.read(imageAt: image)
    }

    /// Images, containers and volumes as the container service accounts for
    /// them — across everything it runs, not only AgentVM's instances.
    public func storageSummary() async throws -> StorageSummary {
        let usage = try await ClientDiskUsage.get()
        func kind(_ resource: ResourceUsage) -> StorageSummary.Kind {
            StorageSummary.Kind(
                count: resource.total, active: resource.active, bytes: resource.sizeInBytes,
                reclaimable: resource.reclaimable)
        }
        return StorageSummary(
            images: kind(usage.images), containers: kind(usage.containers), volumes: kind(usage.volumes))
    }
}
