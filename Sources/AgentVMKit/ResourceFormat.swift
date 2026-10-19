//
//  ResourceFormat.swift
//  How the dashboard writes its numbers: short, rounded the way Activity
//  Monitor and Finder round them, and the same in every place they appear.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

public enum ResourceFormat {
    /// A share, 0…1, as a whole percentage. Anything above nothing but below
    /// one percent reads "<1%", so a busy-but-light instance never shows 0%.
    public static func percent(_ share: Double) -> String {
        let value = min(1, max(0, share)) * 100
        if value == 0 { return "0%" }
        if value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    /// CPUs' worth of time: "1.4", "8", "<0.1".
    public static func cores(_ value: Double) -> String {
        if value > 0 && value < 0.05 { return "<0.1" }
        return max(0, value).formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Memory, counted in 1024s as Activity Monitor does.
    public static func memory(_ bytes: UInt64) -> String {
        format(bytes, style: .memory)
    }

    /// Space on disk, counted in 1000s as Finder does.
    public static func disk(_ bytes: UInt64) -> String {
        format(bytes, style: .file)
    }

    /// Bytes per second, never in bytes: "0 KB/s", "12 KB/s", "1.2 MB/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return format(0, style: .file) + "/s" }
        let bytes = bytesPerSecond >= Double(UInt64.max) ? UInt64.max : UInt64(bytesPerSecond.rounded())
        return format(bytes, style: .file) + "/s"
    }

    /// How long an instance has been up: "45s", "5m", "2h 13m", "3d 4h".
    public static func uptime(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = interval < 60 ? [.second] : [.day, .hour, .minute]
        return formatter.string(from: max(0, interval)) ?? ""
    }

    /// When a reading was taken, for a chart being read back: "now",
    /// "18s ago", "1m 30s ago".
    public static func ago(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let remainder = seconds % 60
        return remainder == 0 ? "\(seconds / 60)m ago" : "\(seconds / 60)m \(remainder)s ago"
    }

    /// A chart axis label: the bare figure at zero, so the axis reads "0"
    /// rather than "0 KB/s".
    public static func axis(_ value: Double, _ format: (Double) -> String) -> String {
        value == 0 ? "0" : format(value)
    }

    private static func format(_ bytes: UInt64, style: ByteCountFormatter.CountStyle) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        // "0 KB" rather than "Zero KB", and never a column of "bytes".
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .usePB]
        // Below a gigabyte the adaptive style reads best: "12 KB", "5.2 MB".
        // Above it, it gives two decimals — "40.27 GB" — where three
        // significant figures say as much: "40.3 GB", "544 GB".
        let gigabyte: UInt64 = style == .memory ? 1 << 30 : 1_000_000_000
        formatter.isAdaptive = bytes < gigabyte
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

/// Where a chart's scale should stop.
public enum ResourceScale {
    /// The smallest round figure — 1, 2 or 5 times a power of ten — at or
    /// above `value`, and never below `floor`: a scale that tops out at
    /// "100 KB/s" rather than "87.3 KB/s", halving to round ticks.
    public static func niceCeiling(_ value: Double, floor: Double = 0) -> Double {
        let target = max(value, floor)
        guard target.isFinite, target > 0 else { return max(floor, 1) }
        let magnitude = pow(10, (log10(target)).rounded(.down))
        for step in [1.0, 2, 5, 10] where step * magnitude >= target * (1 - 1e-12) {
            return step * magnitude
        }
        return 10 * magnitude
    }
}
