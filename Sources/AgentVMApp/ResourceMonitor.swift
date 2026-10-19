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

/// How busy this Mac was at one moment, 0…1.
struct HostCPUPoint: Identifiable, Equatable {
    var id: Date { time }
    let time: Date
    let share: Double
}

@MainActor
final class ResourceMonitor: ObservableObject {
    /// How often disk use and storage are read while the dashboard is up.
    private static let slowInterval: TimeInterval = 20
    /// Ten minutes of each instance, for its own page.
    static let instanceSpan: TimeInterval = 600
    /// Two minutes of the totals and of this Mac, for the dashboard's lines.
    static let dashboardSpan: TimeInterval = 120
    /// However often readings come, no history grows past this.
    private static let pointLimit = 2_000

    @Published private(set) var histories: [String: ResourceHistory] = [:]
    @Published private(set) var totals: [ResourceTotals] = []
    /// What each instance's whole bundle takes on this Mac.
    @Published private(set) var diskUsage: [String: UInt64] = [:]
    /// How full each instance's own disk is, as `df` inside it would say.
    @Published private(set) var rootDisks: [String: InstanceDisk] = [:]
    @Published private(set) var storage: StorageSummary?
    @Published private(set) var hostCPU: [HostCPUPoint] = []
    @Published private(set) var hostMemoryInUse: UInt64?
    @Published private(set) var memoryPressure: MemoryPressure?
    @Published private(set) var hostDisk: DiskSpace?

    private var hostTicks: HostCPUTicks?
    private var task: Task<Void, Never>?
    private var watchers = 0
    private var dashboardVisible = false
    private var lastSlowReading = Date.distantPast

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

    private func sample(_ model: AppModel) async {
        let running = model.instances.filter(\.isRunning)
        let gap = SamplingInterval.maximumGap(for: model.samplingInterval)
        var histories = self.histories
        var latest: [ResourcePoint] = []
        for instance in running {
            guard let sample = try? await model.engine.resourceSample(for: instance.fullName) else { continue }
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
        var bundles: [String: UInt64] = [:]
        var disks: [String: InstanceDisk] = [:]
        for instance in model.instances {
            if let bytes = try? await model.engine.diskUsage(of: instance.fullName) { bundles[instance.fullName] = bytes }
            if let disk = await model.engine.rootDisk(of: instance.fullName) { disks[instance.fullName] = disk }
        }
        diskUsage = bundles
        rootDisks = disks
        storage = try? await model.engine.storageSummary()
        // The volume the container service keeps its images and disks on.
        let root = model.daemon?.appRoot.map { URL(filePath: $0) }
        hostDisk =
            root.flatMap(HostResources.diskSpace(at:))
            ?? HostResources.diskSpace(at: URL(filePath: NSHomeDirectory()))
    }
}
