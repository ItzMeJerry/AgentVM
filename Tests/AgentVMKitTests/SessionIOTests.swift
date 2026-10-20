//
//  SessionIOTests.swift
//  A shell session's output has to reach the terminal exactly as the guest wrote
//  it. Chunks that arrive shuffled, or an end-of-stream that overtakes the last
//  chunk, show up as garbled screens and a "session ended" line printed before
//  the output it ends. These run against the session's own pipes: no daemon.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

@Suite("SessionIO")
struct SessionIOTests {

    /// Collects what the stream delivers; touched only on the delivery queue.
    private final class Received: @unchecked Sendable {
        var bytes: [UInt8] = []
        var chunks = 0
        var bytesAtEOF: Int?
        var eofCount = 0
        var inOrder = true
    }

    @Test("Output arrives in the order it was written, and EOF only after the last byte")
    func orderedDelivery() async throws {
        let io = SessionIO()
        let queue = DispatchQueue(label: "agentvm.tests.session")
        let received = Received()

        // Many small writes, each tagged with its number, so a reordering can't
        // hide behind identical content.
        var expected: [UInt8] = []
        for index in 0..<4_000 {
            expected.append(contentsOf: Array("\(index);".utf8))
        }

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            io.beginStreaming(
                on: queue,
                onOutput: { chunk in
                    received.bytes.append(contentsOf: chunk)
                    received.chunks += 1
                },
                onEOF: {
                    received.eofCount += 1
                    received.bytesAtEOF = received.bytes.count
                    done.resume()
                })

            let writer = io.stdio[1]!
            DispatchQueue.global().async {
                for index in 0..<4_000 {
                    writer.write(Data("\(index);".utf8))
                }
                try? writer.close()
            }
        }

        // EOF was delivered once, after every byte.
        queue.sync {}
        #expect(received.eofCount == 1)
        #expect(received.bytesAtEOF == expected.count)
        #expect(received.bytes == expected)
        #expect(received.chunks >= 1)
    }

    @Test("A session with no output still reports EOF exactly once")
    func eofWithoutOutput() async throws {
        let io = SessionIO()
        let queue = DispatchQueue(label: "agentvm.tests.session.empty")
        let received = Received()

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            io.beginStreaming(
                on: queue,
                onOutput: { received.bytes.append(contentsOf: $0) },
                onEOF: {
                    received.eofCount += 1
                    done.resume()
                })
            try? io.stdio[1]!.close()
        }

        queue.sync {}
        #expect(received.bytes.isEmpty)
        #expect(received.eofCount == 1)
    }

    /// How far the guest has written ahead of what the terminal was handed.
    private final class Lead: @unchecked Sendable {
        private let lock = NSLock()
        private var written = 0
        private var delivered = 0
        private(set) var most = 0

        func wrote(_ count: Int) {
            lock.lock()
            written += count
            most = max(most, written - delivered)
            lock.unlock()
        }

        func handedOver(_ count: Int) {
            lock.lock()
            delivered += count
            lock.unlock()
        }
    }

    @Test(
        "A flood arrives whole and in order, and the guest is held back while the terminal catches up",
        .timeLimit(.minutes(1)))
    func backpressure() async throws {
        let io = SessionIO()
        let queue = DispatchQueue(label: "agentvm.tests.session.flood")
        let received = Received()
        let lead = Lead()
        let total = 24 * 1024 * 1024
        // Each byte says where it belongs, so loss or reordering shows.
        let pattern = (0..<(64 * 1024)).map { UInt8($0 % 251) }

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            io.beginStreaming(
                on: queue,
                onOutput: { chunk in
                    for (index, byte) in chunk.enumerated()
                    where byte != UInt8((received.bytes.count + index) % 251) {
                        received.inOrder = false
                    }
                    received.bytes.append(contentsOf: chunk)
                    // A terminal far slower than the pipe: about 32 MB/s.
                    usleep(UInt32(chunk.count / 32))
                    lead.handedOver(chunk.count)
                },
                onEOF: {
                    received.eofCount += 1
                    received.bytesAtEOF = received.bytes.count
                    done.resume()
                })

            let writer = io.stdio[1]!
            DispatchQueue.global().async {
                var sent = 0
                while sent < total {
                    // Starting each block where the last one left off.
                    let start = sent % 251
                    let block = Array(pattern[start..<(start + 63 * 1024)])
                    writer.write(Data(block))
                    sent += block.count
                    lead.wrote(block.count)
                }
                try? writer.close()
            }
        }

        queue.sync {}
        #expect(received.eofCount == 1)
        #expect(received.bytesAtEOF == received.bytes.count)
        #expect(received.bytes.count >= total)
        #expect(received.inOrder)
        // Held to the backlog's limit plus what's in flight: the pipe, one
        // read, one block being written and one chunk being drawn.
        #expect(lead.most < OutputBacklog.highWater + 1024 * 1024)
        // And the flood was real: without a slow terminal this proves nothing.
        #expect(lead.most > OutputBacklog.lowWater)
    }

    @Test("Closing a session lets its reader go, even while the guest still holds the pipe open", .timeLimit(.minutes(1)))
    func closeEndsStream() async throws {
        let io = SessionIO()
        let queue = DispatchQueue(label: "agentvm.tests.session.close")
        let received = Received()
        // The daemon's copy of the guest's end, which closing ours leaves open.
        let guest = dup(io.stdio[1]!.fileDescriptor)
        defer { Darwin.close(guest) }

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            io.beginStreaming(
                on: queue,
                onOutput: { received.bytes.append(contentsOf: $0) },
                onEOF: {
                    received.eofCount += 1
                    done.resume()
                })
            io.close()
        }

        queue.sync {}
        #expect(received.eofCount == 1)
    }

    @Test("Keystrokes reach the guest in order, and sending never waits for the guest to read", .timeLimit(.minutes(1)))
    func sendingDoesNotWait() async throws {
        let io = SessionIO()
        // Far more than a pipe holds, with nobody reading yet: a send that
        // wrote in place would stop here for good.
        let total = 1024 * 1024
        let typed = (0..<total).map { UInt8($0 % 251) }
        for start in stride(from: 0, to: total, by: 4096) {
            io.send(Array(typed[start..<min(start + 4096, total)]))
        }

        // The guest reads it now.
        let guestInput = io.stdio[0]!
        var read: [UInt8] = []
        while read.count < total {
            let data = guestInput.availableData
            if data.isEmpty { break }
            read.append(contentsOf: data)
        }
        #expect(read == typed)
        io.close()
    }
}
