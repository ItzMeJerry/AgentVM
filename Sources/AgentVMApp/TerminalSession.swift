//
//  TerminalSession.swift
//  One shell session: an exec process inside a running instance, wired to a
//  terminal view.
//
//  Sessions are independent processes. Open as many as you like; closing one
//  never touches the container — only Stop does.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AppKit
import Foundation
import AgentVMKit
import SwiftTerm
import SwiftUI

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case starting
        case running
        case exited(Int32)
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .exited, .failed: true
            default: false
            }
        }
    }

    let id = UUID()
    let instanceName: String
    let command: [String]
    @Published private(set) var state: State = .starting
    /// What the program inside called itself (OSC 0/2), if anything.
    @Published private(set) var programTitle: String?
    /// Reading the scrollback rather than the live screen.
    @Published private(set) var isScrolledBack = false

    /// The view is owned by the session, so switching tabs keeps the scrollback.
    let terminalView: AgentVMTerminalView

    private var session: AgentVMShellSession?
    private var waiter: Task<Void, Never>?
    /// The guest closed its end; everything it wrote has arrived.
    private var outputEnded = false

    init(instanceName: String, command: [String], fontSize: CGFloat) {
        self.instanceName = instanceName
        self.command = command
        self.terminalView = AgentVMTerminalView(fontSize: fontSize)
        terminalView.configureNativeColors()
        terminalView.terminalDelegate = self
    }

    var title: String {
        let title = programTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        return title.isEmpty ? command.joined(separator: " ") : title
    }

    var exitDescription: String? {
        switch state {
        case .exited(let code) where code >= 0: "exit \(code)"
        case .exited: "closed"
        case .failed(let message): message
        default: nil
        }
    }

    func start(engine: AgentVMEngine, instance: AgentVMInstance, workingDirectory: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await engine.openSession(
                    in: instance,
                    command: command,
                    workingDirectory: workingDirectory,
                    environment: ["TERM=xterm-256color"])
                self.session = session

                // The output callback holds the view, not the session object, so a
                // closed tab's session can be released as soon as its pipe ends.
                let view = terminalView
                try await session.start(
                    onOutput: { data in
                        Task { @MainActor in view.feed(byteArray: ArraySlice(data)) }
                    },
                    onEOF: { [weak self] in
                        Task { @MainActor in self?.markEnded() }
                    })
                state = .running
                syncSize()

                waiter = Task { [weak self] in
                    let code = await session.wait()
                    await MainActor.run { self?.markExited(code) }
                }

            } catch {
                state = .failed(error.agentVMDisplayMessage)
                writeNotice("\r\n\u{1b}[31m\(error.agentVMDisplayMessage)\u{1b}[0m\r\n")
            }
        }
    }

    private func writeNotice(_ text: String) {
        terminalView.feed(text: text)
    }

    /// The process is gone. Its last bytes may still be in the pipe, so the
    /// teardown waits for EOF (briefly) rather than cutting the stream.
    private func markExited(_ code: Int32) {
        guard !state.isFinished else { return }
        state = .exited(code)
        if outputEnded {
            finish(code: code)
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.finish(code: code)
            }
        }
    }

    /// EOF on the output pipe.
    private func markEnded() {
        outputEnded = true
        if case .exited(let code) = state { finish(code: code) }
    }

    private func finish(code: Int32) {
        guard session != nil else { return }
        writeNotice("\r\n\u{1b}[2m[session ended (exit \(code)) — \(instanceName) is unaffected]\u{1b}[0m\r\n")
        session?.terminate()
        session = nil
    }

    /// Ends this session only. The instance keeps running.
    func terminate() {
        waiter?.cancel()
        session?.terminate()
        session = nil
        if !state.isFinished { state = .exited(-1) }
    }

    func scrollToBottom() {
        terminalView.scrollDown(lines: 1_000_000)
    }

    fileprivate func syncSize() {
        let terminal = terminalView.getTerminal()
        resize(cols: terminal.cols, rows: terminal.rows)
    }

    fileprivate func resize(cols: Int, rows: Int) {
        guard case .running = state, let session else { return }
        Task { await session.resize(cols: cols, rows: rows) }
    }
}

// MARK: - TerminalViewDelegate

extension TerminalSession: TerminalViewDelegate {
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { resize(cols: newCols, rows: newRows) }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            guard !state.isFinished else { return }
            session?.send([UInt8](data))
        }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated { programTitle = title }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {
        MainActor.assumeIsolated {
            let back = source.canScroll && position < 1
            if back != isScrolledBack { isScrolledBack = back }
        }
    }
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        MainActor.assumeIsolated { _ = NSWorkspace.shared.open(url) }
    }
    nonisolated func bell(source: TerminalView) {
        MainActor.assumeIsolated { NSSound.beep() }
    }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

// MARK: - The view

/// Hands SwiftUI the session's own terminal view, so tab switches keep state.
/// Only the selected session is mounted; the view outlives the pane, so a tab
/// that comes back has its scrollback, and it takes the keyboard on arrival.
struct TerminalPane: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(terminal: session.terminalView)
        DispatchQueue.main.async { container.focusTerminal() }
        return container
    }

    func updateNSView(_ view: TerminalContainerView, context: Context) {}
}

/// Gives the terminal a margin in its own background color. A click or a
/// scroll in the margin lands on the terminal, as it would in Terminal.app.
final class TerminalContainerView: NSView {
    static let inset = NSEdgeInsets(top: 6, left: 10, bottom: 4, right: 2)
    let terminal: AgentVMTerminalView

    init(terminal: AgentVMTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        let inset = Self.inset
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateLayer() {
        layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func focusTerminal() {
        guard let window, window.firstResponder !== terminal else { return }
        // Don't pull focus out of a sheet or a text field the user is in.
        if window.attachedSheet == nil { window.makeFirstResponder(terminal) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
    }
}
