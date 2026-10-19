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
                        if tailer.text.isEmpty { emptyLog }
                    }
            }
        }
        // The controls are a bar over the log: the text scrolls under them,
        // softened by the scroll edge effect so they stay legible.
        .safeAreaBar(edge: .top) { controls }
        .overlay(alignment: .bottomTrailing) { jumpToEnd }
        .animation(.bouncy(duration: 0.35), value: follow)
        .task(id: "\(instance.fullName)-\(showingBoot)") {
            follow = true
            tailer.open(instance: instance.fullName, boot: showingBoot, engine: model.engine)
        }
        .onDisappear { tailer.close() }
    }

    /// An instance's main process is the keepalive, which never prints: say so,
    /// rather than promise output that won't come.
    private var emptyLog: some View {
        Group {
            if showingBoot {
                ContentUnavailableView(
                    "No Boot Log Yet", systemImage: "text.alignleft",
                    description: Text("The VM's boot messages appear here once it starts."))
            } else if instance.mode == .instance {
                ContentUnavailableView(
                    "Nothing Printed", systemImage: "text.alignleft",
                    description: Text(
                        "An instance's main process only keeps it alive, so it prints nothing. What your shells print is in Sessions."
                    ))
            } else {
                ContentUnavailableView(
                    "No Output Yet", systemImage: "text.alignleft",
                    description: Text("What the task's command prints appears here."))
            }
        }
        .allowsHitTesting(false)
    }

    private var controls: some View {
        HStack {
            Picker("Log", selection: $showingBoot) {
                Text("Output").tag(false)
                Text("Boot Log").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("The instance's own output, or the VM's boot log")
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tailer.text, forType: .string)
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(tailer.text.isEmpty)
            .help("Copy the whole log")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
