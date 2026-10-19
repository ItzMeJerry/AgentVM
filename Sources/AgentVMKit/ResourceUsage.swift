//
//  ResourceUsage.swift
//  What instances, the container service and this Mac are using: the counters
//  the service reports, turned into the rates and shares a dashboard shows.
//
//  The container service reports running totals — CPU time used, bytes sent —
//  so a rate needs two readings. Everything that turns readings into rates
//  lives here, as plain values, so it's under test.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Darwin
import Foundation

/// One reading of an instance's counters, as the container service reports them.
public struct ResourceSample: Sendable, Equatable {
    public var time: Date
    /// CPU time used since the VM booted, in microseconds.
    public var cpuMicroseconds: UInt64?
    public var memoryUsed: UInt64?
    public var memoryLimit: UInt64?
    public var bytesReceived: UInt64?
    public var bytesSent: UInt64?
    public var bytesRead: UInt64?
    public var bytesWritten: UInt64?
    public var processes: UInt64?

    public init(
        time: Date, cpuMicroseconds: UInt64? = nil, memoryUsed: UInt64? = nil, memoryLimit: UInt64? = nil,
        bytesReceived: UInt64? = nil, bytesSent: UInt64? = nil, bytesRead: UInt64? = nil,
        bytesWritten: UInt64? = nil, processes: UInt64? = nil
    ) {
        self.time = time
        self.cpuMicroseconds = cpuMicroseconds
        self.memoryUsed = memoryUsed
        self.memoryLimit = memoryLimit
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.processes = processes
    }
}

/// A reading next to the one before it: rates and shares, not running totals.
/// A rate is nil until there are two readings to take it from.
public struct ResourcePoint: Sendable, Equatable, Identifiable {
    public var id: Date { time }
    public let time: Date
    /// Cores' worth of CPU time used per second: 1.5 means one and a half busy.
    public let coresInUse: Double?
    /// `coresInUse` as a share of the CPUs the instance was given, 0…1.
    public let cpuShare: Double?
    public let memoryUsed: UInt64?
    public let memoryLimit: UInt64?
    /// Bytes per second.
    public let receiveRate: Double?
    public let sendRate: Double?
    public let readRate: Double?
    public let writeRate: Double?
    public let processes: UInt64?
    /// The CPUs the instance was given, which `cpuShare` is a share of.
    public var allocatedCPUs: Int = 0

    /// `memoryUsed` as a share of `memoryLimit`, 0…1.
    public var memoryShare: Double? {
        guard let used = memoryUsed, let limit = memoryLimit, limit > 0 else { return nil }
        return min(1, Double(used) / Double(limit))
    }
}

/// The recent readings of one instance, as points ready to draw.
public struct ResourceHistory: Sendable, Equatable {
    /// Two minutes at one reading every two seconds.
    public static let defaultCapacity = 60

    /// The most points kept, however close together they come.
    public let capacity: Int
    /// How far back points are kept, if not just by count.
    public let span: TimeInterval?
    /// The longest pause between readings that still reads as one line. After
    /// a longer one — the dashboard was closed, the instance was stopped — the
    /// old points are dropped rather than joined to the new ones by a straight
    /// line that never happened. It follows how often readings are taken; see
    /// `SamplingInterval.maximumGap(for:)`.
    public var maximumGap: TimeInterval
    public private(set) var points: [ResourcePoint] = []
    private var previous: ResourceSample?

    public init(
        capacity: Int = ResourceHistory.defaultCapacity, span: TimeInterval? = nil, maximumGap: TimeInterval = 10
    ) {
        self.capacity = max(1, capacity)
        self.span = span
        self.maximumGap = maximumGap
    }

    public var latest: ResourcePoint? { points.last }

    /// The most recent reading as the service reported it: running totals
    /// since the VM booted, such as bytes received.
    public var lastSample: ResourceSample? { previous }

    /// Past this, a memory limit means "no limit". Inside the VM a cgroup with
    /// none reads `max`, which the service passes on as the largest UInt64.
    static let unlimitedMemory: UInt64 = 1 << 60

    /// Adds a reading. `allocatedMemory` — what the instance was created with —
    /// stands in when the service reports no limit, or none at all.
    public mutating func record(_ sample: ResourceSample, allocatedCPUs: Int, allocatedMemory: UInt64? = nil) {
        defer { previous = sample }
        var before = previous
        if let earlier = before {
            let elapsed = sample.time.timeIntervalSince(earlier.time)
            if elapsed <= 0 || elapsed > maximumGap {
                points.removeAll()
                before = nil
            }
        }
        let elapsed = before.map { sample.time.timeIntervalSince($0.time) } ?? 0

        /// Per second, from two readings of a running total. Nil when there is
        /// no earlier reading, or the total went down — the VM restarted.
        func rate(_ path: KeyPath<ResourceSample, UInt64?>) -> Double? {
            guard let before, elapsed > 0, let now = sample[keyPath: path], let then = before[keyPath: path],
                now >= then
            else { return nil }
            return Double(now - then) / elapsed
        }

        let cores = rate(\.cpuMicroseconds).map { $0 / 1_000_000 }
        let share = cores.map { min(1, max(0, $0 / Double(max(allocatedCPUs, 1)))) }
        let reported = sample.memoryLimit.flatMap { $0 > 0 && $0 < Self.unlimitedMemory ? $0 : nil }
        let fallback = allocatedMemory.flatMap { $0 > 0 && $0 < Self.unlimitedMemory ? $0 : nil }
        points.append(
            ResourcePoint(
                time: sample.time, coresInUse: cores, cpuShare: share,
                memoryUsed: sample.memoryUsed, memoryLimit: reported ?? fallback,
                receiveRate: rate(\.bytesReceived), sendRate: rate(\.bytesSent),
                readRate: rate(\.bytesRead), writeRate: rate(\.bytesWritten),
                processes: sample.processes, allocatedCPUs: max(allocatedCPUs, 0)))
        if let span {
            let oldest = sample.time.addingTimeInterval(-span)
            points.removeAll { $0.time < oldest }
        }
        if points.count > capacity { points.removeFirst(points.count - capacity) }
    }
}

/// How often the dashboard takes its readings, and what follows from it.
public enum SamplingInterval {
    /// The choices offered, in seconds.
    public static let choices: [TimeInterval] = [1, 2, 5, 10]
    public static let standard: TimeInterval = 2

    /// One of the choices: a stored value that isn't one — an old build's,
    /// or a hand edit — reads as the standard.
    public static func validated(_ value: TimeInterval) -> TimeInterval {
        choices.contains(value) ? value : standard
    }

    /// The longest pause that still draws as one line: three readings' worth,
    /// so one missed reading doesn't break it, and never under ten seconds.
    public static func maximumGap(for interval: TimeInterval) -> TimeInterval {
        max(10, interval * 3)
    }

    /// "1 second", "5 seconds".
    public static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
}

/// Every instance's latest point, added up.
public struct ResourceTotals: Sendable, Equatable, Identifiable {
    public var id: Date { time }
    public var time: Date
    public var coresInUse: Double = 0
    public var memoryUsed: UInt64 = 0
    public var memoryLimit: UInt64 = 0
    /// Bytes per second.
    public var receiveRate: Double = 0
    public var sendRate: Double = 0
    public var readRate: Double = 0
    public var writeRate: Double = 0
    public var processes: UInt64 = 0
    /// The CPUs of the instances whose CPU use is known — what `coresInUse`
    /// is a share of.
    public var allocatedCPUs = 0

    public init(time: Date) { self.time = time }

    /// `coresInUse` as a share of `allocatedCPUs`, 0…1.
    public var cpuShare: Double? {
        guard allocatedCPUs > 0 else { return nil }
        return min(1, max(0, coresInUse / Double(allocatedCPUs)))
    }

    /// `memoryUsed` as a share of `memoryLimit`, 0…1.
    public var memoryShare: Double? {
        guard memoryLimit > 0 else { return nil }
        return min(1, Double(memoryUsed) / Double(memoryLimit))
    }

    /// Missing values count as nothing rather than making the total unknown: an
    /// instance that just started still has its memory counted. Its CPUs join
    /// the total only once its CPU use is known, so the share isn't diluted by
    /// an instance with no reading yet.
    public static func sum(_ points: [ResourcePoint], at time: Date) -> ResourceTotals {
        var totals = ResourceTotals(time: time)
        for point in points {
            if let cores = point.coresInUse {
                totals.coresInUse += cores
                totals.allocatedCPUs += point.allocatedCPUs
            }
            totals.memoryUsed = adding(totals.memoryUsed, point.memoryUsed)
            totals.memoryLimit = adding(totals.memoryLimit, point.memoryLimit)
            totals.processes = adding(totals.processes, point.processes)
            totals.receiveRate += point.receiveRate ?? 0
            totals.sendRate += point.sendRate ?? 0
            totals.readRate += point.readRate ?? 0
            totals.writeRate += point.writeRate ?? 0
        }
        return totals
    }

    /// The numbers come from inside a guest: a total that would overflow stops
    /// at the top rather than crashing the app.
    private static func adding(_ total: UInt64, _ value: UInt64?) -> UInt64 {
        let (sum, overflow) = total.addingReportingOverflow(value ?? 0)
        return overflow ? .max : sum
    }
}

/// What the container service keeps on disk, from its own accounting. It
/// covers every container it runs, not only AgentVM's.
public struct StorageSummary: Sendable, Equatable {
    public struct Kind: Sendable, Equatable {
        public var count: Int
        public var active: Int
        public var bytes: UInt64
        public var reclaimable: UInt64

        public init(count: Int, active: Int, bytes: UInt64, reclaimable: UInt64) {
            self.count = count
            self.active = active
            self.bytes = bytes
            self.reclaimable = reclaimable
        }
    }

    public var images: Kind
    public var containers: Kind
    public var volumes: Kind

    public init(images: Kind, containers: Kind, volumes: Kind) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
    }

    public var totalBytes: UInt64 { images.bytes + containers.bytes + volumes.bytes }
    public var reclaimableBytes: UInt64 { images.reclaimable + containers.reclaimable + volumes.reclaimable }
}

/// The Mac's own CPU time, in scheduler ticks since boot, across all cores.
public struct HostCPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// How busy the Mac was between two readings, 0…1. Nil when no time passed
    /// or a counter went backwards.
    public static func busyShare(from earlier: HostCPUTicks, to later: HostCPUTicks) -> Double? {
        guard later.user >= earlier.user, later.system >= earlier.system, later.idle >= earlier.idle,
            later.nice >= earlier.nice
        else { return nil }
        let busy = (later.user - earlier.user) + (later.system - earlier.system) + (later.nice - earlier.nice)
        let total = busy + (later.idle - earlier.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }
}

/// How hard macOS is working to find memory — what Activity Monitor's Memory
/// Pressure graph shows. Memory that's nearly all in use is normal on a Mac;
/// pressure is the sign that it's short.
public enum MemoryPressure: Sendable, Equatable {
    case normal, warning, critical

    /// From the kernel's level, which uses the `DISPATCH_MEMORYPRESSURE_*`
    /// values: 1 normal, 2 warning, 4 critical.
    public init(level: Int32) {
        switch level {
        case ...1: self = .normal
        case 2...3: self = .warning
        default: self = .critical
        }
    }
}

/// A volume's size and what's free on it, as Finder counts it: purgeable
/// space — caches macOS clears on demand — counts as free.
public struct DiskSpace: Sendable, Equatable {
    public var total: UInt64
    public var available: UInt64

    public init(total: UInt64, available: UInt64) {
        self.total = total
        self.available = min(available, total)
    }

    public var used: UInt64 { total - available }
    public var usedShare: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// This Mac's processor, memory and disk, read from the kernel directly.
public enum HostResources {
    public static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }
    public static var processorCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    public static func memoryPressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return MemoryPressure(level: level)
    }

    /// The volume holding `url`.
    public static func diskSpace(at url: URL) -> DiskSpace? {
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
            ]),
            let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return DiskSpace(total: UInt64(total), available: UInt64(max(0, available)))
    }

    /// Memory in use the way Activity Monitor counts it: app memory, wired and
    /// compressed.
    public static func memoryInUse() -> UInt64? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages =
            UInt64(statistics.internal_page_count) - min(
                UInt64(statistics.internal_page_count), UInt64(statistics.purgeable_count))
            + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    public static func cpuTicks() -> HostCPUTicks? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = load.cpu_ticks
        return HostCPUTicks(
            user: UInt64(ticks.0), system: UInt64(ticks.1), idle: UInt64(ticks.2), nice: UInt64(ticks.3))
    }
}
