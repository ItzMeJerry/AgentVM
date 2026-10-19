//
//  LayoutPicker.swift
//  Snap Layouts, as Windows offers them: every template drawn as its zones;
//  clicking a zone arranges the sessions into that template with the focused
//  session in the zone you clicked. Below, whether dividers snap or move freely.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMLayout
import SwiftUI

struct LayoutPicker: View {
    /// The template the layout has the shape of right now, if any.
    let current: LayoutTemplate?
    @Binding var mode: ResizeMode
    let choose: (_ template: LayoutTemplate, _ zone: Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Snap Layouts").font(.headline)
                Text("Click the zone the focused session should go in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(96), spacing: 12), count: 4), alignment: .leading,
                spacing: 12
            ) {
                ForEach(LayoutTemplate.allCases) { template in
                    TemplateTile(template: template, isCurrent: template == current) { zone in
                        choose(template, zone)
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("Dividers")
                Picker("Dividers", selection: $mode) {
                    Text("Snap").tag(ResizeMode.snap)
                    Text("Free").tag(ResizeMode.free)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(
                mode == .snap
                    ? "Dragging a divider snaps it to halves, thirds and quarters."
                    : "Dragging a divider places it anywhere."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 456)
    }
}

/// One template, drawn as its zones. Each zone is its own target.
private struct TemplateTile: View {
    let template: LayoutTemplate
    let isCurrent: Bool
    let choose: (Int) -> Void

    @State private var hovered: Int?

    private static let size = CGSize(width: 88, height: 56)

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(template.zones.enumerated()), id: \.offset) { index, zone in
                    let rect = CGRect(
                        x: zone.minX * Self.size.width, y: zone.minY * Self.size.height,
                        width: zone.width * Self.size.width, height: zone.height * Self.size.height
                    )
                    .insetBy(dx: 1.5, dy: 1.5)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(hovered == index ? Color.accentColor : Color.secondary.opacity(0.28))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hovered = index } else if hovered == index { hovered = nil }
                        }
                        .onTapGesture { choose(index) }
                        .accessibilityElement()
                        .accessibilityLabel("\(template.title), zone \(index + 1)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { choose(index) }
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isCurrent ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isCurrent ? 2 : 1)
            }
            Text(template.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 96)
        }
    }
}
