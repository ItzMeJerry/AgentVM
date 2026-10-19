//
//  SessionIO.swift
//  The pipes that carry one shell session between the guest process and a
//  terminal view.
//
//  The container API takes plain file handles for a process's stdio and, with a
//  terminal requested, the pty lives inside the guest — so the host side is just
//  two pipes, and the view on this end can be anything.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import ContainerAPIClient
import ContainerizationOS
import Foundation

public final class SessionIO: @unchecked Sendable {
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var closed = false

    /// Writing into a pipe whose reader has gone raises SIGPIPE, which would
    /// take the whole app down. Sessions end that way routinely.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public init() {
        _ = Self.ignoreSIGPIPE
    }

    /// The handles handed to the daemon. stderr is nil: with a terminal, the
    /// guest's pty already merges it into stdout.
    public var stdio: [FileHandle?] {
        [stdinPipe.fileHandleForReading, stdoutPipe.fileHandleForWriting, nil]
    }

    /// Streams everything the guest writes, read on a thread of its own and
    /// delivered on `queue`: every chunk in the order it was read, and EOF only
    /// after the last of them. A serial dispatch queue guarantees that order —
    /// the same arrangement SwiftTerm's own `LocalProcess` uses — where a Swift
    /// `Task` per chunk would not, and chunks could reach the screen shuffled.
    ///
    /// A plain blocking read loop rather than `FileHandle.readabilityHandler`:
    /// the handler delivers the first chunk and then stops re-arming on these
    /// pipes, which silently truncates a session's output.
    public func beginStreaming(
        on queue: DispatchQueue,
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        let descriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    let chunk = Array(buffer[0..<count])
                    queue.async { onOutput(chunk) }
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                queue.async { onEOF() }
                return
            }
        }
        thread.name = "agentvm.session.reader"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Hands the daemon's ends of the pipes over: once the process is started
    /// they belong to it, and holding copies here would keep EOF from arriving.
    public func closeAfterStart() {
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
    }

    /// Keystrokes on their way to the guest. A closed session swallows them
    /// rather than failing.
    public func send(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !bytes.isEmpty else { return }
        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        var offset = 0
        bytes.withUnsafeBufferPointer { buffer in
            while offset < bytes.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, bytes.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    closed = true
                    return
                }
                offset += written
            }
        }
    }

    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
    }
}

/// One shell session, from the caller's side: bytes in, bytes out, a size, and
/// an exit code. The container process behind it stays inside AgentVMKit.
public final class AgentVMShellSession: @unchecked Sendable {
    private let io: SessionIO
    private var process: (any ClientProcess)?

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
        guard let process else { return }
        io.beginStreaming(on: queue, onOutput: onOutput, onEOF: onEOF)
        try await process.start()
        io.closeAfterStart()
    }

    public func send(_ bytes: [UInt8]) {
        io.send(bytes)
    }

    public func resize(cols: Int, rows: Int) async {
        guard let process, cols > 0, rows > 0 else { return }
        try? await process.resize(Terminal.Size(width: UInt16(cols), height: UInt16(rows)))
    }

    /// The process's exit code, once it finishes.
    public func wait() async -> Int32 {
        guard let process else { return -1 }
        return (try? await process.wait()) ?? -1
    }

    /// Ends this session and nothing else — the instance keeps running.
    public func terminate() {
        let process = self.process
        self.process = nil
        Task { try? await process?.kill(SIGKILL) }
        io.close()
    }
}
