//
//  ResourceMonitor.swift
//  Samples every running instance and this Mac while AgentVM's window is
//  open — every 2 seconds unless "Read every" says otherwise — so the
//  dashboard opens onto history rather than an empty chart. Disk use and
//  storage take longer to work out and change slowly: those are read only
//  while the dashboard itself is on screen.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import Foundation
import Observation

/// How busy this Mac was at one moment, 0…1.
struct HostCPUPoint: Identifiable, Equatable {
    var id: Date { time }
    let time: Date
    let share: Double
}

/// Observable, so each card redraws for its own figures: the disk cards
/// every 20 seconds, when those are read and have changed, not every round.
@MainActor
@Observable
final class ResourceMonitor {
    /// How often disk use and storage are read while the dashboard is up.
    private static let slowInterval: TimeInterval = 20
    /// Ten minutes of each instance, for its own page.
    static let instanceSpan: TimeInterval = 600
    /// Two minutes of the totals and of this Mac, for the dashboard's lines.
    static let dashboardSpan: TimeInterval = 120
    /// However often readings come, no history grows past this.
    private static let pointLimit = 2_000

    private(set) var histories: [String: ResourceHistory] = [:]
    private(set) var totals: [ResourceTotals] = []
    /// What each instance's whole bundle takes on this Mac.
    private(set) var diskUsage: [String: UInt64] = [:]
    /// How full each instance's own disk is, as `df` inside it would say.
    private(set) var rootDisks: [String: InstanceDisk] = [:]
    private(set) var storage: StorageSummary?
    private(set) var hostCPU: [HostCPUPoint] = []
    private(set) var hostMemoryInUse: UInt64?
    private(set) var memoryPressure: MemoryPressure?
    private(set) var hostDisk: DiskSpace?

    @ObservationIgnored private var hostTicks: HostCPUTicks?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var dashboardVisible = false
    @ObservationIgnored private var lastSlowReading = Date.distantPast

    /// Starts sampling; each `begin` needs an `end`.
    func begin(_ model: AppModel) {
        watchers += 1
        guard task == nil else { return }
        start(model)
    }

    /// The interval changed: take a reading now and go on at the new pace,
    /// rather than finish waiting out the old one.
    func intervalChanged(_ model: AppModel) {
        guard task != nil else { return }
        task?.cancel()
        start(model)
    }

    private func start(_ model: AppModel) {
        task = Task { [weak self, weak model] in
            while !Task.isCancelled {
                guard let self, let model else { return }
                await self.sample(model)
                try? await Task.sleep(for: .seconds(model.samplingInterval))
            }
        }
    }

    func end() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        task?.cancel()
        task = nil
    }

    /// The dashboard is on screen: read disk use and storage now, rather
    /// than leave them blank until the next round.
    func dashboardAppeared(_ model: AppModel) {
        dashboardVisible = true
        Task { await readSlowly(model) }
    }

    func dashboardDisappeared() {
        dashboardVisible = false
    }

    /// An instance's page is on screen: its bundle's size, which only the
    /// page shows, now rather than at the next round.
    func pageAppeared(_ model: AppModel) {
        Task { await readSlowly(model) }
    }

    private func sample(_ model: AppModel) async {
        let running = model.instances.filter(\.isRunning)
        let gap = SamplingInterval.maximumGap(for: model.samplingInterval)
        // All at once: each is a round trip to the guest and back, and a
        // round takes as long as the slowest rather than all of them added up.
        let engine = model.engine
        let samples = await withTaskGroup(of: (String, ResourceSample?).self) { group in
            for instance in running {
                group.addTask { (instance.fullName, try? await engine.resourceSample(for: instance.fullName)) }
            }
            var samples: [String: ResourceSample] = [:]
            for await (name, sample) in group { samples[name] = sample }
            return samples
        }
        var histories = self.histories
        var latest: [ResourcePoint] = []
        for instance in running {
            guard let sample = samples[instance.fullName] else { continue }
            var history =
                histories[instance.fullName]
                ?? ResourceHistory(capacity: Self.pointLimit, span: Self.instanceSpan, maximumGap: gap)
            // The interval may have changed since this history began.
            history.maximumGap = gap
            history.record(sample, allocatedCPUs: instance.cpus, allocatedMemory: instance.memoryBytes)
            histories[instance.fullName] = history
            if let point = history.latest { latest.append(point) }
        }
        // An instance that stopped or went away keeps no line: a restarted one
        // starts a new one.
        let names = Set(running.map(\.fullName))
        histories = histories.filter { names.contains($0.key) }

        // After a pause — the window was closed, the Mac slept — the old totals
        // would join the new ones with a straight line that never happened.
        let now = Date()
        var totals = self.totals
        var hostCPU = self.hostCPU
        if let last = totals.last, now.timeIntervalSince(last.time) > gap { totals.removeAll() }
        if let last = hostCPU.last, now.timeIntervalSince(last.time) > gap {
            hostCPU.removeAll()
            hostTicks = nil
        }
        let oldest = now.addingTimeInterval(-Self.dashboardSpan)
        totals.append(ResourceTotals.sum(latest, at: now))
        totals.removeAll { $0.time < oldest }

        if let ticks = HostResources.cpuTicks() {
            if let previous = hostTicks, let share = HostCPUTicks.busyShare(from: previous, to: ticks) {
                hostCPU.append(HostCPUPoint(time: now, share: share))
            }
            hostTicks = ticks
        }
        hostCPU.removeAll { $0.time < oldest }

        self.histories = histories
        self.totals = totals
        self.hostCPU = hostCPU
        hostMemoryInUse = HostResources.memoryInUse()
        memoryPressure = HostResources.memoryPressure()

        if dashboardVisible, Date().timeIntervalSince(lastSlowReading) >= Self.slowInterval {
            await readSlowly(model)
        }
    }

    private func readSlowly(_ model: AppModel) async {
        lastSlowReading = Date()
        let engine = model.engine
        var disks: [String: InstanceDisk] = [:]
        for instance in model.instances {
            if let disk = await engine.rootDisk(of: instance.fullName) { disks[instance.fullName] = disk }
        }
        rootDisks = disks
        // A bundle's size is shown on its instance's page and nowhere else.
        if let page = model.dashboardInstance, let bytes = try? await engine.diskUsage(of: page) {
            diskUsage = [page: bytes]
        } else {
            diskUsage = [:]
        }
        storage = try? await engine.storageSummary()
        // The volume the container service keeps its images and disks on. Its
        // space free for important use takes some 15 ms to work out: not on
        // the main thread.
        let root = model.daemon?.appRoot.map { URL(filePath: $0) }
        hostDisk = await Task.detached {
            root.flatMap(HostResources.diskSpace(at:)) ?? HostResources.diskSpace(at: URL(filePath: NSHomeDirectory()))
        }.value
    }
}
