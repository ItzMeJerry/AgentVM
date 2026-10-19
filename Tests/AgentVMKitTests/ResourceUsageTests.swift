//
//  ResourceUsageTests.swift
//  The dashboard's numbers: the container service reports running totals, and
//  a rate is the difference between two readings. These pin down what a
//  reading means — and what happens when the readings don't line up: the
//  first one, a VM that restarted, a pause in sampling.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

@Suite("Resource usage")
struct ResourceUsageTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func sample(
        at seconds: TimeInterval, cpu: UInt64? = nil, memory: UInt64? = nil, limit: UInt64? = nil,
        received: UInt64? = nil, sent: UInt64? = nil, read: UInt64? = nil, written: UInt64? = nil
    ) -> ResourceSample {
        ResourceSample(
            time: start.addingTimeInterval(seconds), cpuMicroseconds: cpu, memoryUsed: memory, memoryLimit: limit,
            bytesReceived: received, bytesSent: sent, bytesRead: read, bytesWritten: written, processes: 3)
    }

    @Test("The first reading shows memory straight away, but no rates until there's a second")
    func firstReading() throws {
        var history = ResourceHistory()
        history.record(sample(at: 0, cpu: 5_000_000, memory: 300, limit: 1_000), allocatedCPUs: 4)
        let point = try #require(history.latest)
        #expect(point.memoryUsed == 300)
        #expect(point.memoryShare == 0.3)
        #expect(point.coresInUse == nil)
        #expect(point.cpuShare == nil)
        #expect(point.receiveRate == nil)
        #expect(point.processes == 3)
    }

    @Test("CPU is cores' worth of time per second, and a share of the CPUs the instance was given")
    func cpu() throws {
        var history = ResourceHistory()
        history.record(sample(at: 0, cpu: 10_000_000), allocatedCPUs: 4)
        history.record(sample(at: 2, cpu: 13_000_000), allocatedCPUs: 4)
        let point = try #require(history.latest)
        #expect(point.coresInUse == 1.5, "3 s of CPU time in 2 s is one and a half cores")
        #expect(point.cpuShare == 0.375, "1.5 of 4 CPUs")
    }

    @Test("The share never passes the whole allocation, though the cores figure does")
    func cpuCap() throws {
        // The VM runtime adds an overhead core, so a guest can use more than it
        // was given.
        var history = ResourceHistory()
        history.record(sample(at: 0, cpu: 0), allocatedCPUs: 4)
        history.record(sample(at: 2, cpu: 10_000_000), allocatedCPUs: 4)
        let point = try #require(history.latest)
        #expect(point.coresInUse == 5)
        #expect(point.cpuShare == 1)
    }

    @Test("Network and disk totals become bytes per second")
    func rates() throws {
        var history = ResourceHistory()
        history.record(sample(at: 0, received: 1_000, sent: 500, read: 0, written: 4_096), allocatedCPUs: 1)
        history.record(sample(at: 4, received: 9_000, sent: 900, read: 8_192, written: 4_096), allocatedCPUs: 1)
        let point = try #require(history.latest)
        #expect(point.receiveRate == 2_000)
        #expect(point.sendRate == 100)
        #expect(point.readRate == 2_048)
        #expect(point.writeRate == 0)
    }

    @Test("A total that went down — the VM restarted — gives no rate, and counts again from there")
    func restart() throws {
        var history = ResourceHistory()
        history.record(sample(at: 0, cpu: 90_000_000, received: 50_000), allocatedCPUs: 2)
        history.record(sample(at: 2, cpu: 1_000_000, received: 100), allocatedCPUs: 2)
        let reset = try #require(history.latest)
        #expect(reset.coresInUse == nil)
        #expect(reset.receiveRate == nil)

        history.record(sample(at: 4, cpu: 2_000_000, received: 300), allocatedCPUs: 2)
        let after = try #require(history.latest)
        #expect(after.coresInUse == 0.5)
        #expect(after.receiveRate == 100)
    }

    @Test("After a long pause the line starts over, rather than joining two moments by a straight line")
    func gap() throws {
        var history = ResourceHistory(maximumGap: 10)
        history.record(sample(at: 0, cpu: 0, memory: 100), allocatedCPUs: 1)
        history.record(sample(at: 2, cpu: 1_000_000, memory: 100), allocatedCPUs: 1)
        #expect(history.points.count == 2)

        history.record(sample(at: 60, cpu: 2_000_000, memory: 200), allocatedCPUs: 1)
        #expect(history.points.count == 1)
        let point = try #require(history.latest)
        #expect(point.memoryUsed == 200)
        #expect(point.coresInUse == nil, "no rate across the gap")
    }

    @Test("A clock that went backwards starts the line over too")
    func backwards() throws {
        var history = ResourceHistory()
        history.record(sample(at: 10, cpu: 1_000_000), allocatedCPUs: 1)
        history.record(sample(at: 5, cpu: 2_000_000), allocatedCPUs: 1)
        #expect(history.points.count == 1)
        #expect(history.latest?.coresInUse == nil)
    }

    @Test("A history keeps only its most recent points")
    func capacity() throws {
        var history = ResourceHistory(capacity: 3)
        for second in 0..<5 {
            history.record(sample(at: Double(second), memory: UInt64(second)), allocatedCPUs: 1)
        }
        #expect(history.points.map(\.memoryUsed) == [2, 3, 4])
    }

    @Test("A counter the service didn't report stays unknown, never zero")
    func missing() throws {
        var history = ResourceHistory()
        history.record(sample(at: 0, cpu: 1_000_000), allocatedCPUs: 1)
        history.record(sample(at: 2), allocatedCPUs: 1)
        let point = try #require(history.latest)
        #expect(point.coresInUse == nil)
        #expect(point.memoryUsed == nil)
        #expect(point.memoryShare == nil)
    }

    @Test("Memory as a share of its limit, never more than all of it")
    func memoryShare() {
        let half = ResourcePoint(
            time: start, coresInUse: nil, cpuShare: nil, memoryUsed: 512, memoryLimit: 1_024, receiveRate: nil,
            sendRate: nil, readRate: nil, writeRate: nil, processes: nil)
        #expect(half.memoryShare == 0.5)
        let over = ResourcePoint(
            time: start, coresInUse: nil, cpuShare: nil, memoryUsed: 2_000, memoryLimit: 1_000, receiveRate: nil,
            sendRate: nil, readRate: nil, writeRate: nil, processes: nil)
        #expect(over.memoryShare == 1)
        let unlimited = ResourcePoint(
            time: start, coresInUse: nil, cpuShare: nil, memoryUsed: 2_000, memoryLimit: 0, receiveRate: nil,
            sendRate: nil, readRate: nil, writeRate: nil, processes: nil)
        #expect(unlimited.memoryShare == nil)
    }

    @Test("Totals add every instance up, counting what's unknown as nothing")
    func totals() {
        let busy = ResourcePoint(
            time: start, coresInUse: 1.5, cpuShare: 0.75, memoryUsed: 300, memoryLimit: 1_000, receiveRate: 10,
            sendRate: 5, readRate: 0, writeRate: 2, processes: 4)
        let fresh = ResourcePoint(
            time: start, coresInUse: nil, cpuShare: nil, memoryUsed: 200, memoryLimit: 2_000, receiveRate: nil,
            sendRate: nil, readRate: nil, writeRate: nil, processes: 1)
        let totals = ResourceTotals.sum([busy, fresh], at: start)
        #expect(totals.coresInUse == 1.5)
        #expect(totals.memoryUsed == 500)
        #expect(totals.memoryLimit == 3_000)
        #expect(totals.receiveRate == 10)
        #expect(totals.sendRate == 5)
        #expect(totals.writeRate == 2)
        #expect(ResourceTotals.sum([], at: start).memoryUsed == 0)
    }

    @Test("No memory limit reads as the memory the instance was given, never as 16 exabytes")
    func unlimitedMemory() throws {
        // A cgroup with no limit reads `max` inside the VM, which reaches the
        // app as the largest UInt64. Added up, that would crash the totals.
        var history = ResourceHistory()
        history.record(sample(at: 0, memory: 300, limit: .max), allocatedCPUs: 1, allocatedMemory: 1_024)
        #expect(history.latest?.memoryLimit == 1_024)

        history.record(sample(at: 2, memory: 300, limit: .max), allocatedCPUs: 1)
        #expect(history.latest?.memoryLimit == nil, "nothing to fall back on")
        #expect(history.latest?.memoryShare == nil)

        history.record(sample(at: 4, memory: 300, limit: 2_048), allocatedCPUs: 1, allocatedMemory: 1_024)
        #expect(history.latest?.memoryLimit == 2_048, "a real limit wins over the allocation")

        history.record(sample(at: 6, memory: 300), allocatedCPUs: 1, allocatedMemory: 1_024)
        #expect(history.latest?.memoryLimit == 1_024, "no limit reported at all")
    }

    @Test("Totals that would overflow stop at the top instead of crashing")
    func totalsOverflow() {
        let huge = ResourcePoint(
            time: start, coresInUse: nil, cpuShare: nil, memoryUsed: .max - 1, memoryLimit: nil, receiveRate: nil,
            sendRate: nil, readRate: nil, writeRate: nil, processes: .max)
        let more = ResourcePoint(
            time: start, coresInUse: nil, cpuShare: nil, memoryUsed: 10, memoryLimit: nil, receiveRate: nil,
            sendRate: nil, readRate: nil, writeRate: nil, processes: 3)
        let totals = ResourceTotals.sum([huge, more], at: start)
        #expect(totals.memoryUsed == .max)
        #expect(totals.processes == .max)
    }

    @Test("The total CPU share counts only the CPUs of instances with a reading")
    func totalCPUShare() {
        let busy = ResourcePoint(
            time: start, coresInUse: 1, cpuShare: 0.5, memoryUsed: nil, memoryLimit: 1_000, receiveRate: nil,
            sendRate: nil, readRate: nil, writeRate: nil, processes: 2, allocatedCPUs: 2)
        let starting = ResourcePoint(
            time: start, coresInUse: nil, cpuShare: nil, memoryUsed: nil, memoryLimit: 1_000, receiveRate: nil,
            sendRate: nil, readRate: nil, writeRate: nil, processes: 1, allocatedCPUs: 6)
        let totals = ResourceTotals.sum([busy, starting], at: start)
        #expect(totals.allocatedCPUs == 2, "the instance still starting has no CPU reading yet")
        #expect(totals.cpuShare == 0.5)
        #expect(totals.processes == 3)
        #expect(totals.memoryShare == 0, "no memory reading counts as none used")
        #expect(ResourceTotals.sum([], at: start).cpuShare == nil, "nothing running is no share, not 0%")
    }

    @Test("A history's points carry the CPUs the instance was given")
    func allocation() throws {
        var history = ResourceHistory()
        history.record(sample(at: 0, cpu: 0), allocatedCPUs: 4)
        #expect(history.latest?.allocatedCPUs == 4)
        history.record(sample(at: 2, cpu: 0), allocatedCPUs: -1)
        #expect(history.latest?.allocatedCPUs == 0, "a nonsense count is none")
    }

    @Test("Storage adds images, containers and volumes, and what could be reclaimed")
    func storage() {
        let summary = StorageSummary(
            images: .init(count: 3, active: 2, bytes: 1_000, reclaimable: 400),
            containers: .init(count: 2, active: 1, bytes: 300, reclaimable: 100),
            volumes: .init(count: 0, active: 0, bytes: 0, reclaimable: 0))
        #expect(summary.totalBytes == 1_300)
        #expect(summary.reclaimableBytes == 500)
    }

    @Test("The Mac's busy share comes from the difference between two tick counts")
    func hostBusy() {
        let earlier = HostCPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let later = HostCPUTicks(user: 160, system: 70, idle: 900, nice: 70)
        #expect(HostCPUTicks.busyShare(from: earlier, to: later) == 0.5, "100 busy ticks of 200")
        #expect(HostCPUTicks.busyShare(from: earlier, to: earlier) == nil, "no time passed")
        #expect(HostCPUTicks.busyShare(from: later, to: earlier) == nil, "counters went backwards")
    }

    @Test("This Mac reports its memory in use and its CPU ticks")
    func hostReadings() async throws {
        let memory = try #require(HostResources.memoryInUse())
        #expect(memory > 0)
        #expect(memory <= HostResources.physicalMemory)
        #expect(HostResources.processorCount > 0)
        let first = try #require(HostResources.cpuTicks())
        try await Task.sleep(for: .milliseconds(300))
        let second = try #require(HostResources.cpuTicks())
        if let share = HostCPUTicks.busyShare(from: first, to: second) {
            #expect((0...1).contains(share))
        }
    }

    @Test("Memory pressure follows the kernel's levels")
    func pressure() throws {
        #expect(MemoryPressure(level: 1) == .normal)
        #expect(MemoryPressure(level: 2) == .warning)
        #expect(MemoryPressure(level: 4) == .critical)
        #expect(MemoryPressure(level: 0) == .normal, "a level the kernel doesn't use isn't an alarm")
        _ = try #require(HostResources.memoryPressure(), "this Mac reports a level")
    }

    @Test("Free disk space is never more than the disk")
    func diskSpace() throws {
        let space = DiskSpace(total: 100, available: 250)
        #expect(space.available == 100)
        #expect(space.used == 0)
        #expect(DiskSpace(total: 200, available: 50).usedShare == 0.75)
        #expect(DiskSpace(total: 0, available: 0).usedShare == 0)

        let here = try #require(HostResources.diskSpace(at: FileManager.default.temporaryDirectory))
        #expect(here.total > 0)
        #expect(here.available <= here.total)
        #expect(HostResources.diskSpace(at: URL(filePath: "/no/such/place/\(UUID())")) == nil)
    }
}

@Suite("Resource formatting")
struct ResourceFormatTests {
    @Test("Percentages are whole, and something is never written as nothing")
    func percent() {
        #expect(ResourceFormat.percent(0) == "0%")
        #expect(ResourceFormat.percent(0.004) == "<1%")
        #expect(ResourceFormat.percent(0.184) == "18%")
        #expect(ResourceFormat.percent(1) == "100%")
        #expect(ResourceFormat.percent(1.7) == "100%", "a share past the whole is the whole")
        #expect(ResourceFormat.percent(-0.2) == "0%")
    }

    @Test("CPUs' worth of time keeps one decimal at most")
    func cores() {
        #expect(ResourceFormat.cores(0) == "0")
        #expect(ResourceFormat.cores(0.01) == "<0.1")
        #expect(ResourceFormat.cores(8) == "8")
        #expect(ResourceFormat.cores(1.43).hasPrefix("1"))
        #expect(ResourceFormat.cores(1.43).hasSuffix("4"))
    }

    @Test("Rates are per second and never in bytes")
    func rates() {
        #expect(ResourceFormat.rate(0) == "0 KB/s")
        #expect(ResourceFormat.rate(.nan) == "0 KB/s")
        #expect(ResourceFormat.rate(-5) == "0 KB/s")
        #expect(ResourceFormat.rate(12_000) == "12 KB/s")
        #expect(ResourceFormat.rate(.infinity) == "0 KB/s")
        #expect(ResourceFormat.rate(1e30).hasSuffix("/s"), "too big for UInt64 still formats")
    }

    @Test("Memory counts in 1024s, disk space in 1000s")
    func sizes() {
        #expect(ResourceFormat.memory(512 * 1_024 * 1_024) == "512 MB")
        #expect(ResourceFormat.disk(494_000_000_000) == "494 GB")
        #expect(ResourceFormat.memory(0) == "0 KB")
        #expect(!ResourceFormat.memory(.max).isEmpty)
    }

    @Test("Big sizes keep three significant figures, not two decimals")
    func significantFigures() {
        // Whatever this Mac uses as its decimal separator.
        func plain(_ text: String) -> String { text.replacingOccurrences(of: ",", with: ".") }
        #expect(plain(ResourceFormat.memory(43_315_000_000)) == "40.3 GB", "not 40.34 GB")
        #expect(plain(ResourceFormat.disk(543_530_000_000)) == "544 GB", "not 543.53 GB")
        #expect(plain(ResourceFormat.disk(1_450_000_000_000)) == "1.45 TB")
        #expect(plain(ResourceFormat.memory(5_452_595)) == "5.2 MB", "small sizes keep the adaptive style")
        #expect(ResourceFormat.rate(12_345) == "12 KB/s", "not 12.3 KB/s")
    }

    @Test("Uptime shows its two largest units")
    func uptime() {
        #expect(ResourceFormat.uptime(45) == "45s")
        #expect(ResourceFormat.uptime(300) == "5m")
        #expect(ResourceFormat.uptime(8_000) == "2h 13m")
        #expect(ResourceFormat.uptime(400_000) == "4d 15h")
        #expect(ResourceFormat.uptime(-3) == "0s")
    }

    @Test("A reading being looked back at says how long ago it was")
    func ago() {
        #expect(ResourceFormat.ago(0.4) == "now")
        #expect(ResourceFormat.ago(18) == "18s ago")
        #expect(ResourceFormat.ago(90) == "1m 30s ago")
        #expect(ResourceFormat.ago(120) == "2m ago")
    }
}

@Suite("Chart scales")
struct ResourceScaleTests {
    @Test("A scale stops at 1, 2 or 5 times a power of ten, at or above the highest reading")
    func niceCeiling() {
        #expect(ResourceScale.niceCeiling(87_300) == 100_000)
        #expect(ResourceScale.niceCeiling(100_000) == 100_000, "a round figure is its own ceiling")
        #expect(ResourceScale.niceCeiling(120_000) == 200_000)
        #expect(ResourceScale.niceCeiling(2_100) == 5_000)
        #expect(ResourceScale.niceCeiling(0.37) == 0.5)
        #expect(ResourceScale.niceCeiling(6_000_000) == 10_000_000)
    }

    @Test("A quiet chart keeps its floor, so a few bytes don't fill it")
    func floor() {
        #expect(ResourceScale.niceCeiling(12, floor: 64_000) == 100_000)
        #expect(ResourceScale.niceCeiling(0, floor: 64_000) == 100_000)
        #expect(ResourceScale.niceCeiling(0) == 1, "nothing at all still has a scale")
        #expect(ResourceScale.niceCeiling(.nan, floor: 5) == 5)
    }

    @Test("An axis reads 0 at zero, not 0 KB/s")
    func axis() {
        #expect(ResourceFormat.axis(0, ResourceFormat.rate) == "0")
        #expect(ResourceFormat.axis(50_000, ResourceFormat.rate) == "50 KB/s")
    }

    @Test("A history keeps the latest reading's running totals")
    func lastSample() {
        var history = ResourceHistory()
        #expect(history.lastSample == nil)
        let sample = ResourceSample(time: Date(), bytesReceived: 12_000)
        history.record(sample, allocatedCPUs: 1)
        #expect(history.lastSample == sample)
    }
}

@Suite("Sampling interval")
struct SamplingIntervalTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("A history kept by span drops what's older than it, however often readings come")
    func span() {
        var history = ResourceHistory(capacity: 1_000, span: 15, maximumGap: 30)
        for second in stride(from: 0.0, through: 30, by: 10) {
            history.record(ResourceSample(time: start.addingTimeInterval(second), memoryUsed: UInt64(second)), allocatedCPUs: 1)
        }
        #expect(history.points.map(\.memoryUsed) == [20, 30], "the reading at 15 seconds back is kept, 10 is not")
    }

    @Test("Readings ten seconds apart still make one line")
    func slowReadings() {
        var history = ResourceHistory(span: 600, maximumGap: SamplingInterval.maximumGap(for: 10))
        for second in stride(from: 0.0, through: 40, by: 10.2) {
            history.record(ResourceSample(time: start.addingTimeInterval(second), cpuMicroseconds: UInt64(second * 1e6)), allocatedCPUs: 1)
        }
        #expect(history.points.count == 4, "no reset between readings")
        #expect(history.latest?.coresInUse != nil)
    }

    @Test("The gap that breaks a line grows with the interval, and is never under ten seconds")
    func gap() {
        #expect(SamplingInterval.maximumGap(for: 1) == 10)
        #expect(SamplingInterval.maximumGap(for: 2) == 10)
        #expect(SamplingInterval.maximumGap(for: 5) == 15)
        #expect(SamplingInterval.maximumGap(for: 10) == 30)
    }

    @Test("A stored interval that isn't one of the choices reads as the standard")
    func validated() {
        #expect(SamplingInterval.validated(5) == 5)
        #expect(SamplingInterval.validated(0) == SamplingInterval.standard)
        #expect(SamplingInterval.validated(3.5) == SamplingInterval.standard)
        #expect(SamplingInterval.choices.contains(SamplingInterval.standard))
    }

    @Test("Intervals read as words")
    func describe() {
        #expect(SamplingInterval.describe(1) == "1 second")
        #expect(SamplingInterval.describe(10) == "10 seconds")
    }
}
