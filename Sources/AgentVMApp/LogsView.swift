//
//  LogsView.swift
//  The instance's own output, and the VM boot log, tailed from the log files
//  the daemon hands over as file handles.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AppKit
import AgentVMKit
import SwiftUI

@MainActor
final class LogTailer: ObservableObject {
    @Published var text: String = ""
    @Published var error: String?

    private var handle: FileHandle?
    private var follower: Task<Void, Never>?
    private var offset: UInt64 = 0

    /// Tails the log by polling from a byte offset. The log is a regular file,
    /// where a readability handler tells you nothing useful — a file is always
    /// "readable" — so the offset is the thing to track.
    func open(instance: String, boot: Bool, engine: AgentVMEngine) {
        close()
        follower = Task { [weak self] in
            do {
                let handle = try await engine.logHandle(for: instance, boot: boot)
                guard let self, !Task.isCancelled else {
                    try? handle.close()
                    return
                }
                self.handle = handle
                while !Task.isCancelled {
                    self.readNewBytes()
                    try? await Task.sleep(for: .milliseconds(700))
                }
            } catch {
                self?.error = error.agentVMDisplayMessage
            }
        }
    }

    private func readNewBytes() {
        guard let handle else { return }
        do {
            let end = try handle.seekToEnd()
            if end < offset {
                // The log was rotated or truncated under us; start over.
                offset = 0
                text = ""
            }
            guard end > offset else { return }
            try handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: Int(end - offset))
            offset = end
            if let chunk = String(data: data, encoding: .utf8) {
                text += chunk
            }
        } catch {
            self.error = error.agentVMDisplayMessage
        }
    }

    func close() {
        follower?.cancel()
        follower = nil
        try? handle?.close()
        handle = nil
        offset = 0
        text = ""
        error = nil
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var tailer = LogTailer()
    @State private var showingBoot = false
    @State private var follow = true
    let instance: AgentVMInstance

    var body: some View {
        Group {
            if let error = tailer.error {
                ContentUnavailableView("No logs", systemImage: "doc.text", description: Text(error))
            } else {
                LogTextView(text: tailer.text, follow: $follow)
                    .overlay {
                        if tailer.text.isEmpty {
                            Text("No output yet")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
        }
        // The controls float over the log as glass; the text runs under them.
        .overlay(alignment: .top) { controls }
        .overlay(alignment: .bottomTrailing) { jumpToEnd }
        .animation(.bouncy(duration: 0.35), value: follow)
        .task(id: "\(instance.fullName)-\(showingBoot)") {
            follow = true
            tailer.open(instance: instance.fullName, boot: showingBoot, engine: model.engine)
        }
        .onDisappear { tailer.close() }
    }

    private var controls: some View {
        HStack {
            GlassSegmented(
                selection: $showingBoot,
                options: [(false, "Output"), (true, "Boot log")])
                .help("The instance's own output, or the VM's boot log")
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tailer.text, forType: .string)
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(tailer.text.isEmpty)
            .help("Copy the whole log")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var jumpToEnd: some View {
        if !follow {
            Button {
                follow = true
            } label: {
                Label("Follow", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help("Back to the newest output, and keep following it")
            .padding(18)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}

/// A segmented switch that behaves like the window toolbar's: one capsule of
/// glass, the chosen segment a lighter capsule. Press and hold it and it lifts
/// into a glass lens you can drag to another segment; let go and it settles
/// on the nearest one. A tap on another segment slides it there.
struct GlassSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    /// Equal segments, like the toolbar's Sessions / Logs / Inspect switch.
    var segmentWidth: CGFloat = 86

    /// Where the thumb's centre is while it's held; nil when it's at rest.
    @State private var dragCenter: CGFloat?
    /// A segment pressed but not yet released, other than the selected one.
    @State private var pressed: Int?
    @State private var hovered: Int?

    private let height: CGFloat = 28
    private let inset: CGFloat = 3

    private var selectedIndex: Int { options.firstIndex { $0.0 == selection } ?? 0 }
    private var holding: Bool { dragCenter != nil }
    /// The segment the thumb is over, which is the one that reads as chosen.
    private var litIndex: Int { dragCenter.map(index(at:)) ?? selectedIndex }

    private func center(of index: Int) -> CGFloat { segmentWidth * (CGFloat(index) + 0.5) }
    private func index(at x: CGFloat) -> Int {
        min(max(Int((x / segmentWidth).rounded(.down)), 0), options.count - 1)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let wash = pressed ?? hovered, wash != selectedIndex, !holding {
                Capsule()
                    .fill(.primary.opacity(pressed == wash ? 0.08 : 0.04))
                    .frame(width: segmentWidth, height: height)
                    .offset(x: center(of: wash) - segmentWidth / 2)
            }
            thumb
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].1)
                        .font(.system(size: 13))
                        .foregroundStyle(index == litIndex ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(width: segmentWidth, height: height)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: segmentWidth * CGFloat(options.count), height: height)
        .contentShape(Capsule())
        .gesture(drag)
        .onContinuousHover { phase in
            if case .active(let location) = phase {
                hovered = index(at: location.x)
            } else {
                hovered = nil
            }
        }
        .padding(inset)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.snappy(duration: 0.28), value: selection)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.82), value: dragCenter)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].1).tag(options[index].0)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var thumb: some View {
        Capsule()
            .fill(.primary.opacity(holding ? 0.05 : 0.12))
            .frame(width: segmentWidth, height: height)
            // Held, the thumb is a lens of glass lifted off the track.
            .glassEffect(holding ? .clear.interactive() : .identity, in: .capsule)
            .scaleEffect(holding ? CGSize(width: 1.08, height: 1.22) : CGSize(width: 1, height: 1))
            .shadow(color: .black.opacity(holding ? 0.18 : 0), radius: 8, y: 2)
            .offset(x: (dragCenter ?? center(of: selectedIndex)) - segmentWidth / 2)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let start = index(at: gesture.startLocation.x)
                if start == selectedIndex || holding {
                    // Holding the thumb: it follows the pointer, kept on the track.
                    let half = segmentWidth / 2
                    let limit = segmentWidth * CGFloat(options.count) - half
                    dragCenter = min(max(center(of: start) + gesture.translation.width, half), limit)
                } else if abs(gesture.translation.width) > 6 {
                    // Dragged from another segment: pick the thumb up from there.
                    pressed = nil
                    let half = segmentWidth / 2
                    let limit = segmentWidth * CGFloat(options.count) - half
                    dragCenter = min(max(gesture.location.x, half), limit)
                } else {
                    pressed = start
                }
            }
            .onEnded { gesture in
                if let dragCenter {
                    selection = options[index(at: dragCenter)].0
                } else if let pressed, index(at: gesture.location.x) == pressed {
                    selection = options[pressed].0
                }
                dragCenter = nil
                pressed = nil
            }
    }
}

/// The log in an AppKit text view: native momentum scrolling, selection, and
/// ⌘F, and it only ever appends — a long log isn't re-laid out on every tick.
/// It follows the end while you're at the end, and leaves you alone while
/// you're reading further up.
private struct LogTextView: NSViewRepresentable {
    let text: String
    @Binding var follow: Bool

    func makeCoordinator() -> Coordinator { Coordinator(follow: $follow) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textColor = .textColor
        // Room for the floating controls; the text scrolls up underneath them.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 48, left: 0, bottom: 0, right: 0)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.follow = $follow
        guard let textView = scrollView.documentView as? NSTextView,
            let storage = textView.textStorage
        else { return }
        let incoming = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        context.coordinator.updating = true
        if incoming.length < storage.length || (storage.length > 0 && incoming.length == 0) {
            storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        } else if incoming.length > storage.length {
            let tail = incoming.substring(from: storage.length)
            storage.append(NSAttributedString(string: tail, attributes: attributes))
        }
        if follow { textView.scrollToEndOfDocument(nil) }
        context.coordinator.updating = false
    }

    final class Coordinator: NSObject {
        var follow: Binding<Bool>
        var updating = false
        private var observer: NSObjectProtocol?

        init(follow: Binding<Bool>) { self.follow = follow }

        func observe(_ scrollView: NSScrollView) {
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView, !self.updating else { return }
                MainActor.assumeIsolated {
                    let clip = scrollView.contentView
                    let documentHeight = scrollView.documentView?.frame.height ?? 0
                    let atEnd = clip.bounds.maxY >= documentHeight - 24
                    if self.follow.wrappedValue != atEnd { self.follow.wrappedValue = atEnd }
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
