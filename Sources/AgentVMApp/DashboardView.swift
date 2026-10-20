//
//  DashboardView.swift
//  Everything at a glance: how the container service stands, what each
//  instance is using, and how much of this Mac is left.
//
//  Every number on it follows the same rules, so they all read the same way:
//  one blue for every line and meter; the status colours only for status, and
//  always beside a word or a symbol; and each chart's value in text next to
//  it, so nothing is only a shape. Pointing at a line reads back that moment.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import AppKit
import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    let monitor: ResourceMonitor
    @Binding var showingNewInstance: Bool

    private var serviceRunning: Bool { model.daemon?.running == true }
    /// Known to be down — not merely not asked yet, as at launch.
    private var serviceDown: Bool { model.daemon?.running == false }
    private var running: [AgentVMInstance] { model.instances.filter(\.isRunning) }
    private var current: ResourceTotals? { running.isEmpty ? nil : monitor.totals.last }
    private var allocatedCPUs: Int { running.reduce(0) { $0 + $1.cpus } }
    private var allocatedMemory: UInt64 { running.reduce(0) { $0 + $1.memoryBytes } }
    /// The totals worth drawing: none while nothing runs.
    private var totals: [ResourceTotals] { running.isEmpty ? [] : monitor.totals }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if serviceDown { ServiceDownBanner() }
                DashboardSection("Instances", accessory: IntervalPicker()) {
                    TileGrid {
                        cpuTile
                        memoryTile
                        networkTile
                        diskActivityTile
                    }
                    InstanceTable(monitor: monitor, showingNewInstance: $showingNewInstance)
                }
                DashboardSection("This Mac") {
                    TileGrid {
                        macCPUTile
                        macMemoryTile
                        freeDiskTile
                        storageTile
                    }
                }
                if serviceRunning, let daemon = model.daemon { ServiceFooter(status: daemon) }
            }
            .padding(20)
            .frame(maxWidth: 1_200)
            .frame(maxWidth: .infinity)
        }
        .background(DashboardColor.page)
    }

    /// The window's subtitle while the dashboard is up: how many run, and
    /// which container service they run on.
    static func subtitle(for model: AppModel) -> String {
        guard let daemon = model.daemon else { return "" }
        guard daemon.running else { return "Container service not running" }
        let running = model.instances.filter(\.isRunning).count
        var parts = [model.instances.isEmpty ? "No instances" : "\(running) of \(model.instances.count) running"]
        if let release = daemon.release { parts.append("container \(release)") }
        return parts.joined(separator: " · ")
    }

    private var nothingRunning: String { serviceDown ? "Service not running" : "Nothing running" }

    // MARK: - Instances

    private var cpuTile: some View {
        SparkTile(
            label: "CPU",
            value: current?.cpuShare.map(ResourceFormat.percent) ?? "—",
            detail: current.map { "\(ResourceFormat.cores($0.coresInUse)) of \(allocatedCPUs) CPUs in use" }
                ?? nothingRunning,
            points: totals.compactMap { total in total.cpuShare.map { SparkPoint(time: total.time, value: $0) } },
            upperBound: 1,
            format: .percent
        )
        .help("How busy the running instances are, as a share of the CPUs they were given")
    }

    private var memoryTile: some View {
        SparkTile(
            label: "Memory",
            value: current.map { ResourceFormat.memory($0.memoryUsed) } ?? "—",
            suffix: current == nil ? nil : "of \(ResourceFormat.memory(allocatedMemory))",
            detail: current == nil
                ? nothingRunning : "Across \(running.count) running \(running.count == 1 ? "instance" : "instances")",
            points: totals.map { SparkPoint(time: $0.time, value: Double($0.memoryUsed)) },
            upperBound: Double(allocatedMemory),
            format: .memory
        )
        .help("Memory in use inside the running instances, file cache included, out of what they were given")
    }

    private var networkTile: some View {
        SparkTile(
            label: "Network",
            value: current.map { ResourceFormat.rate($0.receiveRate + $0.sendRate) } ?? "—",
            detail: current.map { "↓ \(ResourceFormat.rate($0.receiveRate))   ↑ \(ResourceFormat.rate($0.sendRate))" }
                ?? nothingRunning,
            points: totals.map { SparkPoint(time: $0.time, value: $0.receiveRate + $0.sendRate) },
            upperBound: Self.quietRate,
            format: .rate
        )
        .help("Traffic into and out of the running instances, received ↓ and sent ↑")
    }

    private var diskActivityTile: some View {
        SparkTile(
            label: "Disk activity",
            value: current.map { ResourceFormat.rate($0.readRate + $0.writeRate) } ?? "—",
            detail: current.map { "Read \(ResourceFormat.rate($0.readRate)) · write \(ResourceFormat.rate($0.writeRate))" }
                ?? nothingRunning,
            points: totals.map { SparkPoint(time: $0.time, value: $0.readRate + $0.writeRate) },
            upperBound: Self.quietRate,
            format: .rate
        )
        .help("How fast the running instances read from and write to their disks")
    }

    /// The top of a rate chart while traffic is lighter than this, so a few
    /// bytes of chatter draw as the flat line they are rather than a mountain.
    static let quietRate: Double = 64_000

    // MARK: - This Mac

    private var macCPUTile: some View {
        SparkTile(
            label: "CPU",
            value: monitor.hostCPU.last.map { ResourceFormat.percent($0.share) } ?? "—",
            detail: "\(HostResources.processorCount) cores",
            points: monitor.hostCPU.map { SparkPoint(time: $0.time, value: $0.share) },
            upperBound: 1,
            format: .percent
        )
        .help("How busy this Mac is, instances included")
    }

    private var macMemoryTile: some View {
        let physical = HostResources.physicalMemory
        let used = monitor.hostMemoryInUse
        let severity = Severity(monitor.memoryPressure)
        let pressure =
            switch severity {
            case .normal: "Memory pressure normal"
            case .warning: "Memory pressure high"
            case .critical: "Memory pressure critical"
            }
        return StatTile(
            label: "Memory",
            value: used.map(ResourceFormat.memory) ?? "—",
            suffix: "of \(ResourceFormat.memory(physical))",
            detail: pressure,
            status: severity
        ) {
            MeterTrend(
                share: used.map { Double($0) / Double(max(physical, 1)) } ?? 0, severity: severity,
                caption: running.isEmpty
                    ? "None given to instances" : "\(ResourceFormat.memory(allocatedMemory)) given to running instances")
        }
        .help(
            "Memory in use on this Mac, counted as Activity Monitor counts it. Pressure, not use, says whether it's running short."
        )
    }

    private var freeDiskTile: some View {
        let disk = monitor.hostDisk
        let free = disk.map { 1 - $0.usedShare } ?? 1
        let severity: Severity = free < 0.05 ? .critical : free < 0.10 ? .warning : .normal
        let detail =
            switch severity {
            case .critical: "Almost out of space"
            case .warning: "Running low on space"
            case .normal: disk.map { "\(ResourceFormat.disk($0.used)) used" } ?? ""
            }
        return StatTile(
            label: "Free disk space",
            value: disk.map { ResourceFormat.disk($0.available) } ?? "—",
            suffix: disk.map { "of \(ResourceFormat.disk($0.total))" },
            detail: detail,
            status: severity
        ) {
            MeterTrend(share: disk?.usedShare ?? 0, severity: severity, caption: "Holds images and instance disks")
        }
        .help("Space left on the disk the container service keeps its images and instance disks on")
    }

    private var storageTile: some View {
        let storage = monitor.storage
        return StatTile(
            label: "Container storage",
            value: storage.map { ResourceFormat.disk($0.totalBytes) } ?? "—",
            detail: storage.map { "\(ResourceFormat.disk($0.reclaimableBytes)) reclaimable" }
                ?? (serviceDown ? "Service not running" : "Reading…")
        ) {
            LinesTrend(lines: storage.map(Self.storageLines) ?? [])
        }
        .help(
            "Everything the container service keeps — images, container disks and volumes — including containers that aren't AgentVM's"
        )
    }

    private static func storageLines(_ storage: StorageSummary) -> [String] {
        func counted(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
        let images = "\(counted(storage.images.count, "image")) · \(ResourceFormat.disk(storage.images.bytes))"
        var others = counted(storage.containers.count, "container")
        var othersBytes = storage.containers.bytes
        if storage.volumes.count > 0 {
            others += ", \(counted(storage.volumes.count, "volume"))"
            othersBytes += storage.volumes.bytes
        }
        return [images, "\(others) · \(ResourceFormat.disk(othersBytes))"]
    }
}

/// A chart value back in bytes, without trapping on one that won't fit.
func bytes(_ value: Double) -> UInt64 {
    guard value.isFinite, value > 0 else { return 0 }
    return value >= 18_000_000_000_000_000_000 ? .max : UInt64(value)
}

// MARK: - Colours

enum DashboardColor {
    /// The one hue every line and meter uses. Run through the dataviz palette
    /// checks against both card colours: inside the lightness band, enough
    /// chroma, and at least 3:1 contrast.
    static let series = Color(light: 0x2a78d6, dark: 0x3987e5, contrastLight: 0x1b5bb0, contrastDark: 0x4a93ea)
    /// A lighter step of the same blue, for a meter's empty part — so a meter
    /// reads as one bar whatever its level.
    static let track = Color(light: 0xcde2fb, dark: 0x0d366b, contrastLight: 0xa9c8f3, contrastDark: 0x1d4c8f)
    /// The cards: white on the page, or one step above it in dark mode — the
    /// colours a grouped form draws its sections in, so the dashboard sits
    /// beside Inspect without a seam.
    static let card = Color(light: 0xffffff, dark: 0x313131, contrastLight: 0xffffff, contrastDark: 0x1c1c1c)
    static let page = Color(nsColor: .underPageBackgroundColor)
    /// A card's edge, which Increase Contrast makes a firm line.
    static let border = Color(
        nsColor: NSColor(name: nil) { appearance in
            let contrast = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            let strong = contrast == .accessibilityHighContrastAqua || contrast == .accessibilityHighContrastDarkAqua
            return NSColor.separatorColor.withAlphaComponent(strong ? 1 : 0.6)
        })
    /// Hairline grid: recessive, one step off the card.
    static let grid = Color(nsColor: .separatorColor)
}

extension Color {
    /// One sRGB colour for the light appearance and another for the dark, each
    /// with a stronger step for Increase Contrast.
    init(light: UInt32, dark: UInt32, contrastLight: UInt32? = nil, contrastDark: UInt32? = nil) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let hex: UInt32
                switch appearance.bestMatch(from: [
                    .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                ]) {
                case .darkAqua?: hex = dark
                case .accessibilityHighContrastAqua?: hex = contrastLight ?? light
                case .accessibilityHighContrastDarkAqua?: hex = contrastDark ?? dark
                default: hex = light
                }
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
            })
    }
}

/// Status, never decoration: each level comes with a symbol and words.
enum Severity {
    case normal, warning, critical

    init(_ pressure: MemoryPressure?) {
        switch pressure {
        case .warning: self = .warning
        case .critical: self = .critical
        default: self = .normal
        }
    }

    var tint: Color {
        switch self {
        case .normal: DashboardColor.series
        case .warning: .orange
        case .critical: .red
        }
    }

    var track: Color { self == .normal ? DashboardColor.track : tint.opacity(0.22) }

    var symbol: String {
        switch self {
        case .normal: "checkmark.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

// MARK: - Layout

private struct DashboardSection<Accessory: View, Content: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(_ title: String, accessory: Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.headline)
                accessory
            }
            .padding(.leading, 2)
            content
        }
    }
}

extension DashboardSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: EmptyView(), content: content)
    }
}

/// "Read every 2 seconds", where the figure is a menu: how often the
/// dashboard reads each instance and this Mac. The same setting as in
/// Settings > Dashboard.
struct IntervalPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Read every")
                .foregroundStyle(.secondary)
            Picker("Read every", selection: Bindable(model).samplingInterval) {
                ForEach(SamplingInterval.choices, id: \.self) { interval in
                    Text(SamplingInterval.describe(interval)).tag(interval)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .font(.subheadline)
        .help("How often the dashboard reads each instance and this Mac")
    }
}

/// Four tiles in a row when they fit, two rows of two when they don't — never
/// three and a straggler.
private struct TileGrid<Content: View>: View {
    let content: Content
    @State private var width: CGFloat = 1_000

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let columns = width >= 4 * 168 + 3 * 12 ? 4 : 2
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns),
            alignment: .leading, spacing: 12
        ) {
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(DashboardColor.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DashboardColor.border, lineWidth: 1)
            }
    }
}

extension View {
    /// The dashboard's card: white, or a step above the page in dark mode.
    func dashboardCard() -> some View { modifier(Card()) }
}

// MARK: - Tiles

/// A label, the figure, a line of context, and below them the figure's
/// recent past or its share of a whole.
private struct StatTile<Trend: View>: View {
    let label: String
    let value: String
    let suffix: String?
    let detail: String
    let status: Severity
    let trend: Trend

    init(
        label: String, value: String, suffix: String? = nil, detail: String, status: Severity = .normal,
        @ViewBuilder trend: () -> Trend
    ) {
        self.label = label
        self.value = value
        self.suffix = suffix
        self.detail = detail
        self.status = status
        self.trend = trend()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // Proportional figures: a big number set in tabular ones looks loose.
                Text(value)
                    .font(.title.weight(.semibold))
                if let suffix {
                    Text(suffix)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Group {
                if status == .normal {
                    Text(detail)
                } else {
                    Label {
                        Text(detail)
                    } icon: {
                        Image(systemName: status.symbol).foregroundStyle(status.tint)
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            trend
                .frame(height: 36)
                .padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .combine)
    }
}

/// A tile whose figure has a history: pointing at the line shows the figure as
/// it was then, and how long ago.
private struct SparkTile: View {
    let label: String
    let value: String
    var suffix: String? = nil
    let detail: String
    let points: [SparkPoint]
    let upperBound: Double
    let format: ChartFormat
    @State private var scrub: Date?

    var body: some View {
        let shown = scrub.flatMap { points.nearest(to: $0) }
        StatTile(
            label: label,
            value: shown.map { format($0.value) } ?? value,
            suffix: shown == nil ? suffix : nil,
            detail: shown.map { ResourceFormat.ago(Date().timeIntervalSince($0.time)) } ?? detail
        ) {
            Sparkline(points: points, upperBound: upperBound, scrub: $scrub)
        }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: UITour.scrubTo)) { note in
                guard let fraction = note.object as? Double, let last = points.last else {
                    scrub = nil
                    return
                }
                scrub = points.nearest(to: last.time.addingTimeInterval(-Sparkline.window * (1 - fraction)))?.time
            }
        #endif
    }
}

private struct MeterTrend: View {
    let share: Double
    let severity: Severity
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Meter(share: share, severity: severity)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
    }
}

private struct LinesTrend: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                Text(line).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Marks

/// A share of a whole. The fill carries the severity; the empty part is a
/// lighter step of the same colour.
struct Meter: View {
    let share: Double
    var severity: Severity = .normal

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, share.isFinite ? share : 0))
            ZStack(alignment: .leading) {
                Capsule().fill(severity.track)
                if fraction > 0 {
                    // Never thinner than it is tall, so a sliver still shows.
                    Capsule()
                        .fill(severity.tint)
                        .frame(width: max(geometry.size.height, geometry.size.width * fraction))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - The instance table

private enum ColumnWidth {
    static let cpu: CGFloat = 56
    static let memory: CGFloat = 128
    static let network: CGFloat = 96
    static let disk: CGFloat = 64
    static let spacing: CGFloat = 16
}

/// One row's cells, at the table's column widths.
private struct Columns<Name: View, CPU: View, Memory: View, Network: View, Disk: View>: View {
    let name: Name
    let cpu: CPU
    let memory: Memory
    let network: Network
    let disk: Disk

    init(
        @ViewBuilder name: () -> Name, @ViewBuilder cpu: () -> CPU, @ViewBuilder memory: () -> Memory,
        @ViewBuilder network: () -> Network, @ViewBuilder disk: () -> Disk
    ) {
        self.name = name()
        self.cpu = cpu()
        self.memory = memory()
        self.network = network()
        self.disk = disk()
    }

    var body: some View {
        HStack(spacing: ColumnWidth.spacing) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            cpu.frame(width: ColumnWidth.cpu, alignment: .leading)
            memory.frame(width: ColumnWidth.memory, alignment: .leading)
            network.frame(width: ColumnWidth.network, alignment: .leading)
            disk.frame(width: ColumnWidth.disk, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }
}

private struct InstanceTable: View {
    @Environment(AppModel.self) private var model
    let monitor: ResourceMonitor
    @Binding var showingNewInstance: Bool

    var body: some View {
        VStack(spacing: 0) {
            Columns {
                Text("Instance")
            } cpu: {
                Text("CPU").help("A share of the CPUs the instance was given")
            } memory: {
                Text("Memory").help("In use inside the instance, file cache included, out of what it was given")
            } network: {
                Text("Network").help("Received ↓ and sent ↑")
            } disk: {
                Text("Disk").help("What its files take, as df inside it would say")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ForEach(model.instances) { instance in
                Divider().padding(.horizontal, 12)
                InstanceUsageRow(
                    instance: instance, history: monitor.histories[instance.fullName],
                    disk: monitor.rootDisks[instance.fullName])
            }

            if model.instances.isEmpty {
                Divider().padding(.horizontal, 12)
                empty
            }
        }
        .padding(4)
        .dashboardCard()
    }

    @ViewBuilder
    private var empty: some View {
        HStack(spacing: 12) {
            Text(model.daemon?.running == false ? "Container service not running" : "No instances yet")
                .foregroundStyle(.secondary)
            Spacer()
            Button("New Instance…") { showingNewInstance = true }
                .buttonStyle(.glass)
                .disabled(model.daemon?.running != true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

private struct InstanceUsageRow: View {
    @Environment(AppModel.self) private var model
    let instance: AgentVMInstance
    let history: ResourceHistory?
    let disk: InstanceDisk?
    @State private var hovered = false

    /// Only a running instance has current figures.
    private var point: ResourcePoint? { instance.isRunning ? history?.latest : nil }

    var body: some View {
        Button {
            model.openDashboardPage(instance.fullName)
        } label: {
            Columns {
                nameCell
            } cpu: {
                cpuCell
            } memory: {
                memoryCell
            } network: {
                networkCell
            } disk: {
                diskCell
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.primary.opacity(hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { hovered = $0 }
        .help("Show \(instance.shortName)'s charts")
        .contextMenu {
            Button("Show Charts", systemImage: "chart.xyaxis.line") { model.openDashboardPage(instance.fullName) }
            Button("Show Instance", systemImage: "macwindow") { model.selection = instance.fullName }
            Button("New Shell Session", systemImage: "terminal") {
                model.selection = instance.fullName
                model.openSession(in: instance)
            }
            .disabled(!instance.isRunning)
            Divider()
            if instance.isRunning {
                Button("Stop", systemImage: "stop.fill") { Task { await model.stop(instance) } }
            } else {
                Button("Start", systemImage: "play.fill") { Task { await model.start(instance) } }
            }
            // The figures say which instances you lean on; this keeps them.
            if model.isLocked(instance) {
                Button("Unlock", systemImage: "lock.open") { model.setLocked(false, instance) }
            } else {
                Button("Lock", systemImage: "lock") { model.setLocked(true, instance) }
                    .disabled(!instance.canLock)
            }
        }
    }

    private var nameCell: some View {
        HStack(spacing: 9) {
            StateDot(state: instance.stateLabel)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(instance.shortName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if model.isLocked(instance) {
                        LockBadge()
                    }
                }
                .animation(LockBadge.animation, value: model.isLocked(instance))
                // The process count goes first when the column is narrow.
                ViewThatFits(in: .horizontal) {
                    Text(statusLine(withProcesses: true))
                    Text(statusLine(withProcesses: false))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    /// "Up 5m · 4 processes" — up, as `docker ps` puts it — or the state.
    private func statusLine(withProcesses: Bool) -> String {
        guard instance.isRunning else { return instance.stateLabel.capitalized }
        var parts = [instance.startedAt.map { "Up \(ResourceFormat.uptime(Date().timeIntervalSince($0)))" } ?? "Running"]
        if withProcesses, let processes = point?.processes {
            parts.append(ResourceFormat.processes(processes))
        }
        return parts.joined(separator: " · ")
    }

    /// Just the figure: its history is on the instance's page.
    @ViewBuilder
    private var cpuCell: some View {
        if let share = point?.cpuShare {
            Text(ResourceFormat.percent(share))
                .font(.callout)
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Missing()
        }
    }

    @ViewBuilder
    private var memoryCell: some View {
        if let point, let used = point.memoryUsed {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ResourceFormat.memory(used))
                        .font(.callout)
                        .monospacedDigit()
                    if let limit = point.memoryLimit {
                        Text("of \(ResourceFormat.memory(limit))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Meter(share: point.memoryShare ?? 0)
            }
        } else {
            Missing()
        }
    }

    @ViewBuilder
    private var networkCell: some View {
        if let point, point.receiveRate != nil || point.sendRate != nil {
            VStack(alignment: .leading, spacing: 2) {
                RateLine(symbol: "arrow.down", rate: point.receiveRate)
                RateLine(symbol: "arrow.up", rate: point.sendRate)
            }
            .accessibilityElement(children: .combine)
        } else {
            Missing()
        }
    }

    @ViewBuilder
    private var diskCell: some View {
        if let disk {
            Text(ResourceFormat.disk(disk.used))
                .font(.callout)
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Missing()
        }
    }
}

private struct RateLine: View {
    let symbol: String
    let rate: Double?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(rate.map(ResourceFormat.rate) ?? "—")
                .monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
    }
}

/// No figure: stopped, or no reading yet.
private struct Missing: View {
    var body: some View {
        Text("—")
            .foregroundStyle(.tertiary)
            .accessibilityLabel("None")
    }
}

// MARK: - Service

private struct ServiceDownBanner: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Severity.critical.symbol)
                .foregroundStyle(Severity.critical.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Container service not running")
                    .font(.headline)
                Text("Instances can't run, and their figures stay empty, until it's up. Start it with container system start.")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }
}

private struct ServiceFooter: View {
    let status: AgentVMEngine.DaemonStatus

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text(line)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 2)
        .help(status.version.map { "\($0), over XPC" } ?? "")
    }

    private var line: String {
        var parts = ["Container service running"]
        if let release = status.release { parts.append(release) }
        if let build = status.build, !build.isEmpty { parts.append("\(build) build") }
        if let root = status.appRoot { parts.append("data in \(Self.abbreviated(root))") }
        return parts.joined(separator: " · ")
    }

    /// `~/Library/…` rather than the full home path.
    private static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.hasPrefix(home) ? "~" + trimmed.dropFirst(home.count) : trimmed
    }
}
