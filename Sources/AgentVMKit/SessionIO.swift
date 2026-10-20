//
//  SessionIO.swift
//  The pipes that carry one shell session between the guest process and a
//  terminal view.
//
//  The container API takes plain file handles for a process's stdio and, with a
//  terminal requested, the pty lives inside the guest — so the host side is just
//  two pipes, and the view on this end can be anything.
//
//  Output is read on a thread of its own into a backlog, and handed to the view
//  a few milliseconds' worth at a time, so keystrokes and redraws get their
//  turn while a program floods the screen. Past a high-water mark the reader
//  stops reading: the pipe fills and the guest waits in write(), as a program
//  does whenever a terminal falls behind. This is how SwiftTerm's own
//  LocalProcess treats a local shell.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import ContainerAPIClient
import ContainerizationOS
import Foundation

final class SessionIO: @unchecked Sendable {
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    /// Closed by `close()` to wake the reader. The read end of `stdoutPipe`
    /// is the reader's alone to close: closed from another thread while a
    /// read is under way, its descriptor could be reused by a file opened
    /// elsewhere in the app, and the reader would read that.
    private let wake = Pipe()
    private let backlog = OutputBacklog()
    /// Keystrokes go out in order on a queue of their own. A write waits
    /// while the guest isn't reading its input — a big paste into a busy
    /// program — and that wait mustn't hang the app.
    private let writer = DispatchQueue(label: "agentvm.session.writer")
    /// Touched only on `writer`.
    private var closed = false

    /// Bytes per read: as much as a pipe holds.
    static let readSize = 64 * 1024
    /// How long one delivery runs before the rest of its queue gets a turn.
    static let deliverySlice: UInt64 = 4_000_000

    /// Writing into a pipe whose reader has gone raises SIGPIPE, which would
    /// take the whole app down. Sessions end that way routinely.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    init() {
        _ = Self.ignoreSIGPIPE
    }

    /// The handles handed to the daemon. stderr is nil: with a terminal, the
    /// guest's pty already merges it into stdout.
    var stdio: [FileHandle?] {
        [stdinPipe.fileHandleForReading, stdoutPipe.fileHandleForWriting, nil]
    }

    /// Streams everything the guest writes, delivered on `queue`: every byte
    /// in the order it was read, and EOF once, after the last of them. A
    /// serial queue keeps that order, where a Swift `Task` per chunk would
    /// not, and chunks could reach the screen shuffled.
    ///
    /// A blocking read loop rather than `FileHandle.readabilityHandler`: the
    /// handler delivers the first chunk and then stops re-arming on these
    /// pipes, which silently truncates a session's output.
    func beginStreaming(
        on queue: DispatchQueue,
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        let backlog = self.backlog
        let output = stdoutPipe.fileHandleForReading
        let wake = self.wake.fileHandleForReading

        @Sendable func deliver() {
            let start = DispatchTime.now().uptimeNanoseconds
            while let item = backlog.next() {
                switch item {
                case .bytes(let chunk): onOutput(chunk)
                case .end: onEOF()
                }
                if DispatchTime.now().uptimeNanoseconds - start >= Self.deliverySlice {
                    queue.async { deliver() }
                    return
                }
            }
        }

        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: Self.readSize)
            var descriptors = [
                pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake.fileDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            while backlog.waitForRoom() {
                if poll(&descriptors, nfds_t(descriptors.count), -1) < 0 {
                    if errno == EINTR { continue }
                    break
                }
                // Closed: whatever the guest still writes goes unread.
                if descriptors[1].revents != 0 { break }
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptors[0].fd, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    if backlog.add(Array(buffer[..<count])) { queue.async { deliver() } }
                } else if count == 0 || errno != EINTR {
                    break
                }
            }
            if backlog.finish() { queue.async { deliver() } }
            try? output.close()
            try? wake.close()
        }
        thread.name = "agentvm.session.reader"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Hands the daemon's ends of the pipes over: once the process is started
    /// they belong to it, and holding copies here would keep EOF from arriving.
    func closeAfterStart() {
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
    }

    /// Keystrokes on their way to the guest. A closed session swallows them
    /// rather than failing.
    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writer.async { [self] in
            guard !closed else { return }
            let fd = stdinPipe.fileHandleForWriting.fileDescriptor
            bytes.withUnsafeBufferPointer { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        // The guest's end has gone.
                        closed = true
                        return
                    }
                }
            }
        }
    }

    /// Ends the session's I/O. Keystrokes already sent go out first; output
    /// not yet delivered is dropped, and EOF follows.
    func close() {
        writer.async { [self] in
            closed = true
            try? stdinPipe.fileHandleForWriting.close()
        }
        backlog.discard()
        try? wake.fileHandleForWriting.close()
        // Still ours if the process never started.
        try? stdoutPipe.fileHandleForWriting.close()
    }
}

/// What the reader has read and the delivery queue hasn't yet handed over.
/// Past `highWater` the reader waits until delivery brings it under
/// `lowWater`: four megabytes is far more than a screen's worth, and far less
/// than an unchecked flood would pile up.
final class OutputBacklog: @unchecked Sendable {
    enum Item {
        case bytes([UInt8])
        case end
    }

    static let highWater = 4 * 1024 * 1024
    static let lowWater = 1 * 1024 * 1024

    private let condition = NSCondition()
    private var chunks: [[UInt8]] = []
    /// Chunks before this one have been delivered.
    private var head = 0
    private var size = 0
    private var ended = false
    private var endDelivered = false
    /// A delivery is on its way to the queue, or running there.
    private var scheduled = false
    private var discarding = false

    /// True when a delivery has to be scheduled for it.
    func add(_ chunk: [UInt8]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !discarding else { return false }
        chunks.append(chunk)
        size += chunk.count
        return claimDelivery()
    }

    /// The reader is done. True when a delivery has to be scheduled for EOF.
    func finish() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        ended = true
        return claimDelivery()
    }

    /// Holds the reader while the backlog is full. False once it's closed.
    func waitForRoom() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if size >= Self.highWater {
            while size > Self.lowWater && !discarding { condition.wait() }
        }
        return !discarding
    }

    /// The next thing to deliver, or nil when there's nothing for now.
    func next() -> Item? {
        condition.lock()
        defer { condition.unlock() }
        if head < chunks.count {
            let chunk = chunks[head]
            head += 1
            size -= chunk.count
            // Delivered chunks go, rather than pile up behind a flood.
            if head == chunks.count || head >= 64 {
                chunks.removeFirst(head)
                head = 0
            }
            if size <= Self.lowWater { condition.signal() }
            return .bytes(chunk)
        }
        scheduled = false
        guard ended, !endDelivered else { return nil }
        endDelivered = true
        return .end
    }

    /// The session closed: what's waiting is dropped and the reader let go.
    func discard() {
        condition.lock()
        defer { condition.unlock() }
        discarding = true
        chunks.removeAll()
        head = 0
        size = 0
        condition.broadcast()
    }

    /// With the lock held.
    private func claimDelivery() -> Bool {
        guard !scheduled else { return false }
        scheduled = true
        return true
    }
}

/// One shell session, from the caller's side: bytes in, bytes out, a size, and
/// an exit code. The container process behind it stays inside AgentVMKit.
public final class AgentVMShellSession: @unchecked Sendable {
    private let io: SessionIO
    /// Never changes, so the threads that wait on it, resize it and kill it
    /// need no lock between them.
    private let process: any ClientProcess

    init(process: any ClientProcess, io: SessionIO) {
        self.process = process
        self.io = io
    }

    /// Starts the guest process and begins delivering its output, in order, on
    /// `queue` (the main queue unless you say otherwise). Call once.
    public func start(
        on queue: DispatchQueue = .main,
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) async throws {
        io.beginStreaming(on: queue, onOutput: onOutput, onEOF: onEOF)
        try await process.start()
        io.closeAfterStart()
    }

    public func send(_ bytes: [UInt8]) {
        io.send(bytes)
    }

    public func resize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0 else { return }
        try? await process.resize(Terminal.Size(width: UInt16(cols), height: UInt16(rows)))
    }

    /// The process's exit code, once it finishes.
    public func wait() async -> Int32 {
        (try? await process.wait()) ?? -1
    }

    /// Ends this session and nothing else — the instance keeps running.
    public func terminate() {
        let process = self.process
        Task { try? await process.kill(SIGKILL) }
        io.close()
    }
}
