//
//  ChartViews.swift
//  The lines on the dashboard and on an instance's page: a 2-point line over
//  a faint wash, in the one series blue, and — while the pointer is over a
//  chart — a hairline at the reading nearest it.
//
//  Each chart is drawn in two layers. Its marks compare equal while its
//  readings stay the same, so they're drawn again only when a reading
//  arrives. The pointer's hairline and dot are an overlay of their own, which
//  is all that redraws as the pointer moves: drawn in one, every step of the
//  pointer rebuilt every chart on the page.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import Charts
import SwiftUI

struct SparkPoint: Identifiable, Equatable {
    let time: Date
    let value: Double
    var id: Date { time }
}

/// A reading at a moment, so the one nearest the pointer can be found.
protocol Timed {
    var time: Date { get }
}

extension SparkPoint: Timed {}
extension ResourcePoint: Timed {}

extension Array where Element: Timed {
    /// The reading nearest a moment.
    func nearest(to time: Date) -> Element? {
        self.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }
}

/// What a chart's scale reads in. A value rather than a closure, so a chart
/// can tell when nothing about it has changed.
enum ChartFormat: Equatable {
    case percent, memory, rate

    func callAsFunction(_ value: Double) -> String {
        switch self {
        case .percent: ResourceFormat.percent(value)
        case .memory: ResourceFormat.memory(bytes(value))
        case .rate: ResourceFormat.rate(value)
        }
    }
}

// MARK: - Sparkline

/// The last two minutes of one figure, on a dashboard tile: no axes, and an
/// end dot ringed in the card's colour.
struct Sparkline: View {
    let points: [SparkPoint]
    /// The top of the scale, unless a reading goes higher.
    let upperBound: Double
    @Binding var scrub: Date?

    /// The span the chart always covers, so a new line grows in from the
    /// right instead of stretching across.
    static let window: TimeInterval = 118

    var body: some View {
        if let last = points.last {
            // Only what fits: the oldest reading can sit a moment before the
            // window, and would be drawn past the chart's left edge.
            let start = last.time.addingTimeInterval(-Self.window)
            SparklinePlot(
                points: points.filter { $0.time >= start }, start: start, end: last.time, upperBound: upperBound,
                scrub: $scrub
            )
            .equatable()
        } else {
            // Nothing to draw yet: a baseline, so the tile doesn't look broken.
            Rectangle()
                .fill(DashboardColor.border)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .accessibilityHidden(true)
        }
    }
}

private struct SparklinePlot: View, Equatable {
    let points: [SparkPoint]
    let start: Date
    let end: Date
    let upperBound: Double
    @Binding var scrub: Date?

    static func == (a: Self, b: Self) -> Bool {
        a.points == b.points && a.start == b.start && a.end == b.end && a.upperBound == b.upperBound
    }

    var body: some View {
        Chart { SeriesMarks(points: points) }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...max(upperBound, points.map(\.value).max() ?? 0, 1e-9))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartOverlay { proxy in ChartMarker(proxy: proxy, points: points, scrub: $scrub) }
            // The figure is in text beside the chart; the line adds its history.
            .accessibilityHidden(true)
    }
}

// MARK: - History chart

/// A figure over time, on axes, on an instance's page: the time along the
/// bottom, the scale on the right, hairline grid. The pointer's moment is
/// marked here and on every chart that shares `scrub`.
struct HistoryChart: View {
    let points: [SparkPoint]
    let start: Date
    let end: Date
    /// The top of the scale, unless a reading goes higher.
    let top: Double
    let format: ChartFormat
    var timeAxis = true
    var height: CGFloat = 132
    @Binding var scrub: Date?

    var body: some View {
        HistoryPlot(
            points: points, start: start, end: end, top: top, format: format, timeAxis: timeAxis, height: height,
            scrub: $scrub
        )
        .equatable()
    }
}

private struct HistoryPlot: View, Equatable {
    let points: [SparkPoint]
    let start: Date
    let end: Date
    let top: Double
    let format: ChartFormat
    let timeAxis: Bool
    let height: CGFloat
    @Binding var scrub: Date?

    static func == (a: Self, b: Self) -> Bool {
        a.points == b.points && a.start == b.start && a.end == b.end && a.top == b.top && a.format == b.format
            && a.timeAxis == b.timeAxis && a.height == b.height
    }

    var body: some View {
        let scale = max(top, points.map(\.value).max() ?? 0, 1e-9)
        let ticks = [start, start.addingTimeInterval(end.timeIntervalSince(start) / 2), end]
        Chart { SeriesMarks(points: points) }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...scale)
            .chartXAxis {
                AxisMarks(values: ticks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(DashboardColor.grid)
                    if timeAxis {
                        AxisValueLabel(anchor: anchor(for: value.index, of: value.count)) {
                            if let date = value.as(Date.self) {
                                Text(ResourceFormat.ago(end.timeIntervalSince(date)))
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                // A short chart has room for its ends only.
                AxisMarks(position: .trailing, values: height < 80 ? [0, scale] : [0, scale / 2, scale]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(DashboardColor.grid)
                    // Clear of the end dot, which sits on the chart's right edge.
                    AxisValueLabel(horizontalSpacing: 9) {
                        if let number = value.as(Double.self) {
                            Text(ResourceFormat.axis(number, format.callAsFunction))
                        }
                    }
                }
            }
            .chartOverlay { proxy in ChartMarker(proxy: proxy, points: points, scrub: $scrub) }
            .frame(height: height)
            // Every figure is in text above the chart.
            .accessibilityHidden(true)
    }

    /// The first time label sits right of its tick and the last left of
    /// it, so neither hangs off the chart.
    private func anchor(for index: Int, of count: Int) -> UnitPoint {
        if index == 0 { return .topLeading }
        if index == count - 1 { return .topTrailing }
        return .top
    }
}

// MARK: - Shared

/// The line, over the wash under it.
private struct SeriesMarks: ChartContent {
    let points: [SparkPoint]

    var body: some ChartContent {
        ForEach(points) { point in
            AreaMark(x: .value("Time", point.time), y: .value("Value", point.value))
                .foregroundStyle(DashboardColor.series.opacity(0.1))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.time), y: .value("Value", point.value))
                .foregroundStyle(DashboardColor.series)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
    }
}

/// The pointer's part of a chart, over its marks: it follows the pointer, and
/// draws the hairline and the dot at the reading nearest it — or the dot
/// alone, on the latest reading, while nothing is pointed at. It reads
/// `scrub` itself, so it redraws on its own as the pointer moves.
private struct ChartMarker: View {
    let proxy: ChartProxy
    let points: [SparkPoint]
    @Binding var scrub: Date?

    var body: some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
            let marked = scrub.flatMap { points.nearest(to: $0) }
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase,
                            let time: Date = proxy.value(atX: location.x - plot.minX),
                            let nearest = points.nearest(to: time)
                        else {
                            scrub = nil
                            return
                        }
                        scrub = nearest.time
                    }
                if let marked, let x = proxy.position(forX: marked.time) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 1, height: plot.height)
                        .position(x: plot.minX + x, y: plot.midY)
                        .allowsHitTesting(false)
                }
                if let dot = marked ?? points.last,
                    let x = proxy.position(forX: dot.time), let y = proxy.position(forY: dot.value)
                {
                    EndDot()
                        .position(x: plot.minX + x, y: plot.minY + y)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// An 8-point dot with a 2-point ring of the card's colour around it, so it
/// stays legible where it sits on the line.
struct EndDot: View {
    var body: some View {
        Circle()
            .fill(DashboardColor.series)
            .padding(2)
            .background(Circle().fill(DashboardColor.card))
            .frame(width: 12, height: 12)
    }
}
