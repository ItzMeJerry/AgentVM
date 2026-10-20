//
//  InstanceUsageView.swift
//  One instance's charts, pushed over the dashboard: CPU, memory, network,
//  disk activity, and how full its disk is.
//
//  The same rules as the dashboard: one blue, status colours only for status,
//  and every figure in text beside its chart. Pointing at any chart shows
//  that moment on all of them, so you can see what memory and the network
//  were doing when the CPU jumped.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import Charts
import SwiftUI

/// How far back the charts reach.
enum ChartRange: String, CaseIterable, Identifiable {
    case twoMinutes, tenMinutes

    var id: String { rawValue }
    var seconds: TimeInterval { self == .twoMinutes ? 120 : 600 }
    var title: String { self == .twoMinutes ? "2 minutes" : "10 minutes" }
}

struct InstanceUsageView: View {
    @Environment(AppModel.self) private var model
    let instance: AgentVMInstance
    let monitor: ResourceMonitor
    /// The moment the pointer is on, in whichever chart: every chart marks it.
    @State private var scrub: Date?
    @State private var width: CGFloat = 1_000

    private var range: ChartRange { model.chartRange }
    private var history: ResourceHistory? { instance.isRunning ? monitor.histories[instance.fullName] : nil }
    private var points: [ResourcePoint] {
        guard let history, let end = history.latest?.time else { return [] }
        let start = end.addingTimeInterval(-range.seconds)
        return history.points.filter { $0.time >= start }
    }
    private var end: Date { history?.latest?.time ?? Date() }
    private var start: Date { end.addingTimeInterval(-range.seconds) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Picker("Range", selection: Bindable(model).chartRange) {
                        ForEach(ChartRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    IntervalPicker()
                    Spacer(minLength: 0)
                }
                if !instance.isRunning { notRunning }
                let columns = width >= 2 * 300 + 12 ? 2 : 1
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns),
                    spacing: 12
                ) {
                    cpuCard
                    memoryCard
                    networkCard
                    diskActivityCard
                }
                DiskCard(disk: monitor.rootDisks[instance.fullName], bundle: monitor.diskUsage[instance.fullName],
                    running: instance.isRunning)
            }
            .padding(20)
            .frame(maxWidth: 1_200)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - 40 } action: { width = $0 }
        }
        // Its bundle's size is read for this page alone.
        .onAppear { monitor.pageAppeared(model) }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: UITour.scrubTo)) { note in
                scrub = (note.object as? Double).map { start.addingTimeInterval(range.seconds * $0) }
            }
        #endif
    }

    /// The window's subtitle while the page is up: state, how long it's been
    /// up, how many processes it runs, what it was given, and its image.
    static func subtitle(for instance: AgentVMInstance, history: ResourceHistory?) -> String {
        var parts = [instance.stateLabel]
        if instance.isRunning, let started = instance.startedAt {
            parts.append("up \(ResourceFormat.uptime(Date().timeIntervalSince(started)))")
        }
        if instance.isRunning, let processes = history?.latest?.processes {
            parts.append(ResourceFormat.processes(processes))
        }
        parts.append(instance.cpus == 1 ? "1 CPU" : "\(instance.cpus) CPUs")
        parts.append(instance.memoryDescription)
        parts.append(instance.imageDisplayName)
        return parts.joined(separator: " · ")
    }

    private var notRunning: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(instance.shortName) is \(instance.stateLabel)")
                    .font(.headline)
                Text("Its CPU, memory and network figures start again when it runs. Its disk is below.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Start") { Task { await model.start(instance) } }
                .buttonStyle(.glassProminent)
                .disabled(!instance.isStopped)
        }
        .padding(14)
        .dashboardCard()
    }

    // MARK: - Cards

    /// The reading the pointer is on, or else the latest.
    private var shown: ResourcePoint? {
        scrub.flatMap { points.nearest(to: $0) } ?? points.last
    }

    private var scrubbing: Bool { scrub != nil && shown != nil }

    /// "18s ago" while the pointer is on a chart, or else `detail`.
    private func detail(_ detail: String) -> String {
        guard scrubbing, let shown else { return detail }
        return ResourceFormat.ago(end.timeIntervalSince(shown.time))
    }

    private func series(_ value: (ResourcePoint) -> Double?) -> [SparkPoint] {
        points.compactMap { point in value(point).map { SparkPoint(time: point.time, value: $0) } }
    }

    private var cpuCard: some View {
        ChartCard(
            label: "CPU",
            value: shown?.cpuShare.map(ResourceFormat.percent) ?? "—",
            detail: detail(
                shown?.coresInUse.map {
                    "\(ResourceFormat.cores($0)) of \(instance.cpus) \(instance.cpus == 1 ? "CPU" : "CPUs") in use"
                } ?? "No reading yet")
        ) {
            HistoryChart(
                points: series(\.cpuShare), start: start, end: end, top: 1, format: .percent,
                scrub: $scrub)
        }
        .help("How busy it is, as a share of the CPUs it was given")
    }

    private var memoryCard: some View {
        let limit = points.last?.memoryLimit ?? instance.memoryBytes
        return ChartCard(
            label: "Memory",
            value: shown?.memoryUsed.map(ResourceFormat.memory) ?? "—",
            suffix: "of \(ResourceFormat.memory(limit))",
            detail: detail(shown?.memoryShare.map { "\(ResourceFormat.percent($0)) of its memory" } ?? "No reading yet")
        ) {
            HistoryChart(
                points: series { $0.memoryUsed.map(Double.init) }, start: start, end: end, top: Double(limit),
                format: .memory, scrub: $scrub)
        }
        .help("Memory in use inside it, file cache included, out of what it was given")
    }

    private var networkCard: some View {
        let received = series(\.receiveRate)
        let sent = series(\.sendRate)
        let top = ResourceScale.niceCeiling(
            max(received.map(\.value).max() ?? 0, sent.map(\.value).max() ?? 0), floor: DashboardView.quietRate)
        let totals = history?.lastSample.flatMap { sample -> String? in
            guard let rx = sample.bytesReceived, let tx = sample.bytesSent else { return nil }
            return "\(ResourceFormat.disk(rx)) received, \(ResourceFormat.disk(tx)) sent since it started"
        }
        return ChartCard(label: "Network", detail: detail(totals ?? "No reading yet")) {
            PairedCharts(
                first: ("Received", "arrow.down", shown?.receiveRate, received),
                second: ("Sent", "arrow.up", shown?.sendRate, sent),
                start: start, end: end, top: top, scrub: $scrub)
        }
        .help("Traffic into and out of it, on one scale so the two compare")
    }

    private var diskActivityCard: some View {
        let read = series(\.readRate)
        let written = series(\.writeRate)
        let top = ResourceScale.niceCeiling(
            max(read.map(\.value).max() ?? 0, written.map(\.value).max() ?? 0), floor: DashboardView.quietRate)
        let totals = history?.lastSample.flatMap { sample -> String? in
            guard let r = sample.bytesRead, let w = sample.bytesWritten else { return nil }
            return "\(ResourceFormat.disk(r)) read, \(ResourceFormat.disk(w)) written since it started"
        }
        return ChartCard(label: "Disk activity", detail: detail(totals ?? "No reading yet")) {
            PairedCharts(
                first: ("Read", "arrow.down.doc", shown?.readRate, read),
                second: ("Written", "arrow.up.doc", shown?.writeRate, written),
                start: start, end: end, top: top, scrub: $scrub)
        }
        .help("How fast it reads from and writes to its disk, on one scale")
    }

}

// MARK: - Pieces

/// A card with a figure and its chart: the label, the figure as it is (or as
/// it was, under the pointer), a line of context, then the chart.
private struct ChartCard<Content: View>: View {
    let label: String
    var value: String? = nil
    var suffix: String? = nil
    let detail: String
    let chart: Content

    init(
        label: String, value: String? = nil, suffix: String? = nil, detail: String,
        @ViewBuilder chart: () -> Content
    ) {
        self.label = label
        self.value = value
        self.suffix = suffix
        self.detail = detail
        self.chart = chart()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(.title.weight(.semibold))
                    if let suffix {
                        Text(suffix)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            chart
                .padding(.top, 10)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }
}

/// Two figures on one scale, one above the other — received and sent, read
/// and written — each with its own line, so neither needs a second colour.
private struct PairedCharts: View {
    typealias Row = (label: String, symbol: String, value: Double?, points: [SparkPoint])
    let first: Row
    let second: Row
    let start: Date
    let end: Date
    let top: Double
    @Binding var scrub: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(first, axis: false)
            row(second, axis: true)
        }
    }

    private func row(_ row: Row, axis: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The figure beside its label, leaving the right for the scale.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: row.symbol)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(row.label)
                    .foregroundStyle(.secondary)
                Text(row.value.map(ResourceFormat.rate) ?? "—")
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .padding(.leading, 4)
            }
            .font(.callout)
            HistoryChart(
                points: row.points, start: start, end: end, top: top, format: .rate,
                timeAxis: axis, height: 52, scrub: $scrub)
        }
    }
}

/// How full the instance's disk is: a ring, blue for what's used.
private struct DiskCard: View {
    let disk: InstanceDisk?
    let bundle: UInt64?
    let running: Bool

    private var severity: Severity {
        guard let disk else { return .normal }
        return disk.share >= 0.97 ? .critical : disk.share >= 0.9 ? .warning : .normal
    }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            UsageRing(share: disk?.share, severity: severity)
                .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 4) {
                Text("Disk")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                if let disk {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(ResourceFormat.disk(disk.used))
                            .font(.title.weight(.semibold))
                        Text("used of \(ResourceFormat.disk(disk.capacity))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    if severity == .normal {
                        Text("\(ResourceFormat.disk(disk.available)) free")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Label {
                            Text(severity == .critical ? "Almost full" : "Filling up")
                        } icon: {
                            Image(systemName: severity.symbol).foregroundStyle(severity.tint)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    Text(footnote(disk))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                } else {
                    Text("—")
                        .font(.title.weight(.semibold))
                    Text("Its disk is made the first time it starts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .help("How full its disk is, as df inside it would say")
    }

    private func footnote(_ disk: InstanceDisk) -> String {
        var lines: [String] = []
        if let onHost = disk.onHost {
            var line = "Takes \(ResourceFormat.disk(onHost)) on this Mac"
            if let bundle, bundle > onHost { line += ", \(ResourceFormat.disk(bundle)) with its kernel and init filesystem" }
            lines.append(line + ".")
        }
        lines.append("Its disk can grow to \(ResourceFormat.disk(disk.capacity)), as far as this Mac's free space allows.")
        if running { lines.append("While it runs, these figures trail it by a minute or so.") }
        return lines.joined(separator: " ")
    }
}

/// A share as a ring: the used part in the series blue — or the status colour
/// once it's nearly full — over a lighter step of the same colour.
private struct UsageRing: View {
    let share: Double?
    let severity: Severity

    private static let lineWidth: CGFloat = 13

    var body: some View {
        let fraction = min(1, max(0, share ?? 0))
        ZStack {
            Circle()
                .stroke(severity.track, lineWidth: Self.lineWidth)
            if fraction > 0 {
                // Never less than a dot, so a sliver of use still shows.
                Circle()
                    .trim(from: 0, to: max(fraction, 0.002))
                    .stroke(severity.tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(share.map(ResourceFormat.percent) ?? "—")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Self.lineWidth / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk")
        .accessibilityValue(share.map { "\(ResourceFormat.percent($0)) used" } ?? "Unknown")
    }
}
